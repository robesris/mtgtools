require_relative 'logging'
require_relative 'browser_manager'
require_relative 'price_processor'
require_relative 'price_extractor'
require_relative 'request_tracker'
require_relative 'legality_checker'
require_relative 'page_manager'
require_relative 'error_handler'

module RequestHandler
  class << self
    def handle_card_info_request(card_name, request_id)
      validate_request(card_name, request_id)
      
      # Check cache first
      tracking_result = RequestTracker.track_request(card_name, request_id)
      return tracking_result[:data] if tracking_result[:cached]

      process_card_request(card_name, request_id)
    end

    private

    def validate_request(card_name, request_id)
      return unless card_name.nil? || card_name.empty?
      
      ErrorHandler.handle_puppeteer_error(ArgumentError.new("No card name provided"), request_id, "Validation")
      raise ArgumentError, "No card name provided"
    end

    def process_card_request(card_name, request_id)
      legality = LegalityChecker.check_legality(card_name, request_id)
      browser = BrowserManager.get_browser
      context = BrowserManager.create_browser_context(request_id)
      
      process_with_browser(card_name, request_id, context, legality)
    rescue => e
      handle_request_error(e, request_id, legality, card_name)
    ensure
      BrowserManager.cleanup_context(request_id)
    end

    def process_with_browser(card_name, request_id, context, legality)
      search_page = nil
      begin
        search_page = setup_search_page(context, request_id)
        return format_error_response('Failed to create search page', legality) unless search_page && !search_page.closed?

        search_url = "https://www.tcgplayer.com/search/magic/product?q=#{CGI.escape(card_name)}&view=grid"
        
        $file_logger.info("Request #{request_id}: Navigating to TCGPlayer search for: #{card_name}")
        $file_logger.info("Request #{request_id}: Search URL: #{search_url}")
        
        # First try a more lenient navigation
        begin
          search_page.goto(search_url, wait_until: 'domcontentloaded')
          $file_logger.info("Request #{request_id}: Initial page load complete")
          
          # Log the page state
          page_state = search_page.evaluate(<<~JS)
            function() {
              return {
                url: window.location.href,
                title: document.title,
                readyState: document.readyState,
                hasSearchResults: !!document.querySelector('.search-results'),
                hasProductCards: !!document.querySelector('.product-card__product'),
                bodyContent: document.body.textContent.slice(0, 500) + '...'
              };
            }
          JS
          $file_logger.info("Request #{request_id}: Initial page state: #{page_state.inspect}")
          
          # Wait a bit for dynamic content
          sleep(2)
          
          # Now wait for network idle
          search_page.wait_for_network_idle
          $file_logger.info("Request #{request_id}: Network idle state reached")
          
          # Log the page state again
          page_state = search_page.evaluate(<<~JS)
            function() {
              return {
                url: window.location.href,
                title: document.title,
                readyState: document.readyState,
                hasSearchResults: !!document.querySelector('.search-results'),
                hasProductCards: !!document.querySelector('.product-card__product'),
                bodyContent: document.body.textContent.slice(0, 500) + '...'
              };
            }
          JS
          $file_logger.info("Request #{request_id}: Final page state: #{page_state.inspect}")
          
        rescue => e
          $file_logger.error("Request #{request_id}: Error during page navigation: #{e.message}")
          $file_logger.error("Request #{request_id}: Navigation error details: #{e.backtrace.join("\n")}")
          raise
        end
        
        return format_error_response('Page closed during navigation', legality) if search_page.closed?
        
        PriceExtractor.add_redirect_prevention(search_page, request_id)
        
        lowest_priced_product = PriceExtractor.extract_lowest_priced_product(search_page, card_name, request_id)
        return format_error_response('No valid product found', legality) unless lowest_priced_product
        
        $file_logger.info("Request #{request_id}: Found lowest priced product: #{lowest_priced_product['title']} at $#{lowest_priced_product['price']}")
        
        prices = process_conditions(lowest_priced_product, context, request_id)
        return format_error_response('No valid prices found', legality) if prices.empty?
        
        format_success_response(prices, legality, card_name, request_id)
      ensure
        if search_page && !search_page.closed?
          begin
            search_page.close
          rescue => e
            $file_logger.error("Request #{request_id}: Error closing search page: #{e.message}")
          end
        end
      end
    end

    def setup_search_page(context, request_id)
      search_page = context.new_page
      PageManager.configure_page(search_page, request_id)
      BrowserManager.add_page(request_id, search_page)
      search_page
    end

    def process_conditions(lowest_priced_product, context, request_id)
      prices = {}
      conditions = ['Near Mint', 'Lightly Played']
      
      conditions.each do |condition|
        break if prices.size >= 2
        
        price = process_single_condition(condition, lowest_priced_product, context, request_id)
        prices[condition] = price if price
      end
      
      prices
    end

    def process_single_condition(condition, lowest_priced_product, context, request_id)
      condition_page = context.new_page
      PageManager.configure_page(condition_page, request_id)
      
      begin
        $file_logger.info("Request #{request_id}: Processing condition: #{condition}")
        
        # Build the correct filtered URL
        delimiter = lowest_priced_product['url'].include?('?') ? '&' : '?'
        condition_param = CGI.escape(condition)
        condition_url = "#{lowest_priced_product['url']}#{delimiter}Condition=#{condition_param}&Language=English"
        condition_page.goto(condition_url, wait_until: 'networkidle0')
        
        PriceExtractor.add_redirect_prevention(condition_page, request_id)
        
        result = PriceExtractor.extract_listing_prices(condition_page, request_id)
        $file_logger.info("Request #{request_id}: Condition result: #{result.inspect}")
        
        return nil unless result && result.is_a?(Hash) && result['success']
        
        # Extract base price and shipping from the result
        base_price = result['base_price'].to_s.gsub(/\$/,'')
        shipping_price = result['shipping'].to_s.gsub(/\$/,'')
        
        {
          'price' => base_price,
          'shipping' => shipping_price,
          'url' => result['url']
        }
      ensure
        condition_page.close
      end
    end

    def format_success_response(prices, legality, card_name, request_id)
      $file_logger.info("Request #{request_id}: Final prices: #{prices.inspect}")
      formatted_prices = {}
      
      prices.each do |condition, data|
        base_price = data['price'].to_s.gsub(/\$/,'')
        shipping_price = data['shipping'] ? data['shipping'].to_s.gsub(/\$/,'') : '0.00'
        total_price = sprintf('%.2f', (base_price.to_f + shipping_price.to_f))
        
        formatted_prices[condition] = {
          'price' => "$#{total_price}",
          'base_price' => "$#{sprintf('%.2f', base_price.to_f)}",
          'shipping' => "$#{sprintf('%.2f', shipping_price.to_f)}",
          'url' => data['url']
        }
      end
      
      response = { 
        prices: formatted_prices,
        legality: legality
      }.to_json
      
      RequestTracker.cache_response(card_name, 'complete', response, request_id)
      response
    end

    def format_error_response(error_message, legality)
      { error: error_message, legality: legality }.to_json
    end

    def handle_request_error(error, request_id, legality, card_name)
      ErrorHandler.handle_puppeteer_error(error, request_id, "Request processing")
      error_response = { 
        error: error.message,
        legality: legality
      }.to_json
      
      RequestTracker.cache_response(card_name, 'error', error_response, request_id)
      error_response
    end
  end
end 