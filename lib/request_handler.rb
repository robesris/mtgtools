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
      if card_name.nil? || card_name.empty?
        ErrorHandler.handle_puppeteer_error(ArgumentError.new("No card name provided"), request_id, "Validation")
        raise ArgumentError, "No card name provided"
      end
    end

    def process_card_request(card_name, request_id)
      begin
        # Get legality using LegalityChecker module
        legality = LegalityChecker.check_legality(card_name, request_id)

        # Use BrowserManager to get browser and context
        browser = BrowserManager.get_browser
        context = BrowserManager.create_browser_context(request_id)
        
        begin
          process_with_browser(card_name, request_id, context, legality)
        ensure
          # Clean up the context and its pages using BrowserManager
          BrowserManager.cleanup_context(request_id)
        end
        
      rescue => e
        handle_request_error(e, request_id, legality)
      end
    end

    def process_with_browser(card_name, request_id, context, legality)
      # Create a new page for the search
      search_page = context.new_page
      PageManager.configure_page(search_page, request_id)
      BrowserManager.add_page(request_id, search_page)
      
      # Navigate to TCGPlayer search
      $file_logger.info("Request #{request_id}: Navigating to TCGPlayer search for: #{card_name}")
      search_url = "https://www.tcgplayer.com/search/magic/product?q=#{CGI.escape(card_name)}&view=grid"
      search_page.goto(search_url, wait_until: 'networkidle0')
      
      # Add redirect prevention
      PriceExtractor.add_redirect_prevention(search_page, request_id)
      
      # Extract the lowest priced product
      lowest_priced_product = PriceExtractor.extract_lowest_priced_product(search_page, card_name, request_id)
      
      if !lowest_priced_product
        $file_logger.error("Request #{request_id}: No valid products found for: #{card_name}")
        return format_error_response('No valid product found', legality)
      end
      
      $file_logger.info("Request #{request_id}: Found lowest priced product: #{lowest_priced_product['title']} at $#{lowest_priced_product['price']}")
      
      prices = process_conditions(lowest_priced_product, context, request_id)
      
      if prices.empty?
        $file_logger.error("Request #{request_id}: No valid prices found for any condition")
        return format_error_response('No valid prices found', legality)
      end
      
      format_success_response(prices, legality, card_name, request_id)
    end

    def process_conditions(lowest_priced_product, context, request_id)
      prices = {}
      found_conditions = 0
      conditions = ['Near Mint', 'Lightly Played']
      
      conditions.each do |condition|
        break if found_conditions >= 2
        
        condition_page = context.new_page
        PageManager.configure_page(condition_page, request_id)
        
        begin
          $file_logger.info("Request #{request_id}: Processing condition: #{condition}")
          
          condition_url = "#{lowest_priced_product['url']}?condition=#{CGI.escape(condition)}"
          condition_page.goto(condition_url, wait_until: 'networkidle0')
          
          PriceExtractor.add_redirect_prevention(condition_page, request_id)
          
          result = PriceExtractor.extract_listing_prices(condition_page, request_id)
          $file_logger.info("Request #{request_id}: Condition result: #{result.inspect}")
          
          if result && result.is_a?(Hash) && result['success']
            prices[condition] = {
              'price' => result['price'].to_s.gsub(/\$/,''),
              'url' => result['url']
            }
            found_conditions += 1
          end
        ensure
          condition_page.close
        end
      end
      
      prices
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

    def handle_request_error(error, request_id, legality)
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