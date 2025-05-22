require_relative 'logging'
require_relative 'browser_manager'
require_relative 'price_processor'
require_relative 'price_extractor'
require_relative 'request_tracker'
require_relative 'legality_checker'
require_relative 'page_manager'
require_relative 'error_handler'
require_relative 'redirect_prevention'

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
      begin
        legality = LegalityChecker.check_legality(card_name, request_id)
        context = BrowserManager.create_browser_context(request_id)
        process_with_browser(card_name, request_id, context, legality)
      rescue => e
        handle_request_error(e, request_id, card_name)
      end
    end

    def process_with_browser(card_name, request_id, context, legality)
      search_page = setup_search_page(context, request_id)
      search_url = "https://www.tcgplayer.com/search/magic/product?q=#{CGI.escape(card_name)}&view=grid"
      
      $file_logger.info("Request #{request_id}: Navigating to TCGPlayer search for: #{card_name}")
      begin
        search_page.goto(search_url, wait_until: 'networkidle0', timeout: 30000)
        $file_logger.info("Request #{request_id}: Successfully loaded search page")
        
        # Log the page content for debugging
        page_content = search_page.content
        $file_logger.debug("Request #{request_id}: Page content length: #{page_content.length}")
        $file_logger.debug("Request #{request_id}: Page title: #{search_page.title}")
        
        RedirectPrevention.add_prevention(search_page, request_id)
        
        lowest_priced_product = PriceExtractor.extract_lowest_priced_product(search_page, card_name, request_id)
        if lowest_priced_product.nil?
          $file_logger.error("Request #{request_id}: Failed to find any products for card: #{card_name}")
          $file_logger.error("Request #{request_id}: Search URL was: #{search_url}")
          return format_error_response('No valid product found', legality)
        end
        
        $file_logger.info("Request #{request_id}: Found lowest priced product: #{lowest_priced_product['title']} at $#{lowest_priced_product['price']}")
        
        prices = process_conditions(lowest_priced_product, context, request_id)
        if prices.empty?
          $file_logger.error("Request #{request_id}: No valid prices found for product: #{lowest_priced_product['title']}")
          return format_error_response('No valid prices found', legality)
        end
        
        format_success_response(prices, legality, card_name, request_id)
      rescue => e
        $file_logger.error("Request #{request_id}: Error during page processing: #{e.message}")
        $file_logger.error("Request #{request_id}: Error backtrace: #{e.backtrace.join("\n")}")
        raise e
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
      
      # Get the base product URL without any condition filters
      base_url = lowest_priced_product['url'].split('?').first
      
      conditions.each do |condition|
        break if prices.size >= 2
        
        price = process_single_condition(condition, base_url, context, request_id)
        prices[condition] = price if price
      end
      
      prices
    end

    def process_single_condition(condition, base_url, context, request_id)
      condition_page = context.new_page
      PageManager.configure_page(condition_page, request_id)
      
      begin
        $file_logger.info("Request #{request_id}: Processing condition: #{condition}")
        
        # Use TCGPlayer's condition filter in the URL
        condition_param = condition.downcase.gsub(' ', '-')
        condition_url = "#{base_url}?condition=#{condition_param}"
        $file_logger.info("Request #{request_id}: Navigating to condition URL: #{condition_url}")
        
        condition_page.goto(condition_url, wait_until: 'networkidle0', timeout: 30000)
        $file_logger.info("Request #{request_id}: Successfully loaded condition page")
        
        RedirectPrevention.add_prevention(condition_page, request_id)
        
        # Wait for listings to load
        begin
          condition_page.wait_for_selector('.listing-item', timeout: 10000)
        rescue => e
          $file_logger.warn("Request #{request_id}: No listings found for condition #{condition}: #{e.message}")
          return nil
        end
        
        result = PriceExtractor.extract_listing_prices(condition_page, request_id)
        $file_logger.info("Request #{request_id}: Condition result: #{result.inspect}")
        
        return nil unless result && result.is_a?(Hash) && result['success']
        
        {
          'price' => result['price'].to_s,
          'url' => result['url']
        }
      rescue => e
        $file_logger.error("Request #{request_id}: Error processing condition #{condition}: #{e.message}")
        nil
      ensure
        condition_page.close
      end
    end

    def format_success_response(prices, legality, card_name, request_id)
      $file_logger.info("Request #{request_id}: Final prices: #{prices.inspect}")
      formatted_prices = PriceProcessor.format_prices(prices)
      
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

    def handle_request_error(e, request_id, card_name = nil)
      error_message = "Request #{request_id}: Request processing error: #{e.message}"
      $file_logger.error(error_message)
      $file_logger.error("Request #{request_id}: Error backtrace: #{e.backtrace.join("\n")}")
      
      {
        'success' => false,
        'message' => "Error processing request for #{card_name || 'card'}: #{e.message}",
        'error' => true
      }.to_json
    end
  end
end 