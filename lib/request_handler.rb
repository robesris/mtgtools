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

    def in_production?
      ENV['RACK_ENV'] == 'production'
    end

    def get_timeout(seconds)
      in_production? ? seconds * 4 : seconds
    end

    def get_navigation_timeout
      in_production? ? 120000 : 30000  # 2 minutes in production, 30 seconds locally
    end

    private

    def validate_request(card_name, request_id)
      if card_name.nil? || card_name.empty?
        ErrorHandler.handle_puppeteer_error(ArgumentError.new("No card name provided"), request_id, "Validation")
        raise ArgumentError, "No card name provided"
      end

      # Validate card name format
      unless card_name.is_a?(String) && card_name.length.between?(1, 200)
        ErrorHandler.handle_puppeteer_error(ArgumentError.new("Invalid card name format"), request_id, "Validation")
        raise ArgumentError, "Invalid card name format"
      end
    end

    def process_card_request(card_name, request_id)
      # Clean and normalize the card name
      card_name = card_name.strip
      $file_logger.info("Request #{request_id}: Processing request for card: '#{card_name}'")
      
      legality = LegalityChecker.check_legality(card_name, request_id)
      # Spin up a fresh headless browser (and context) for each search
      browser = BrowserManager.get_browser
      context = BrowserManager.create_browser_context(request_id)
      
      # Process each condition
      prices = {}
      conditions = ['Near Mint', 'Lightly Played']
      
      conditions.each do |condition|
        break if prices.size >= 2
        result = process_with_browser(card_name, request_id, context, legality, condition)
        if result && result != format_error_response('No valid product found', legality)
          begin
            parsed_result = JSON.parse(result)
            if parsed_result.is_a?(Hash) && parsed_result[condition]
              prices[condition] = parsed_result[condition]
            end
          rescue JSON::ParserError => e
            $file_logger.error("Request #{request_id}: Error parsing result for #{condition}: #{e.message}")
          end
        end
      end
      
      prices.empty? ? format_error_response('No valid prices found', legality) : format_success_response(prices, legality, card_name, request_id)
    rescue => e
      handle_request_error(e, request_id, legality, card_name)
      # On error, also close the headless browser so that a fresh one is used next time
      BrowserManager.cleanup_browser
    ensure
      # Always close the headless browser (and its context) after each search
      BrowserManager.cleanup_context(request_id)
      BrowserManager.cleanup_browser
    end

    def process_with_browser(card_name, request_id, context, legality, condition)
      search_page = nil
      begin
        $file_logger.info("Request #{request_id}: Starting browser process for #{card_name} (#{condition})")
        search_page = setup_search_page(context, request_id)
        return format_error_response('Failed to create search page', legality) unless search_page && !search_page.closed?

        search_url = "https://www.tcgplayer.com/search/magic/product?q=#{CGI.escape(card_name)}&Condition=#{CGI.escape(condition)}&view=grid"
        
        $file_logger.info("Request #{request_id}: Navigating to TCGPlayer search for: #{card_name} (Condition: #{condition})")
        $file_logger.info("Request #{request_id}: Search URL: #{search_url}")
        
        # First try a more lenient navigation
        begin
          navigation_timeout = get_navigation_timeout
          $file_logger.info("Request #{request_id}: Starting page navigation with timeout #{navigation_timeout}ms")
          start_time = Time.now
          search_page.goto(search_url, 
            wait_until: 'domcontentloaded',
            timeout: navigation_timeout
          )
          navigation_time = Time.now - start_time
          $file_logger.info("Request #{request_id}: Initial page load complete in #{navigation_time.round(2)}s")
          
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
          
          # Wait longer for dynamic content to load
          wait_time = get_timeout(5)
          $file_logger.info("Request #{request_id}: Waiting #{wait_time} seconds for dynamic content to load...")
          sleep(wait_time)
          $file_logger.info("Request #{request_id}: Finished waiting for dynamic content")
          
          # Additional check for page state after sleep
          page_state = search_page.evaluate(<<~JS)
            function() {
              return {
                readyState: document.readyState,
                hasSearchResults: !!document.querySelector('.search-results'),
                hasProductCards: !!document.querySelector('.product-card__product'),
                searchResultsCount: document.querySelectorAll('.search-results .product-card__product').length
              };
            }
          JS
          $file_logger.info("Request #{request_id}: Page state after sleep: #{page_state.inspect}")
          
          # Wait for the search results to appear with increased timeout
          begin
            $file_logger.info("Request #{request_id}: Starting wait for search results container with timeout #{get_timeout(45000)}ms")
            start_time = Time.now
            search_page.wait_for_selector('.search-results', timeout: get_timeout(45000))
            wait_time = Time.now - start_time
            $file_logger.info("Request #{request_id}: Search results container found after #{wait_time.round(2)}s")
          rescue => e
            $file_logger.error("Request #{request_id}: Error waiting for search results: #{e.message}")
            $file_logger.error("Request #{request_id}: Search results error details: #{e.backtrace.join("\n")}")
            raise
          end

          # Wait for the product card to appear with increased timeout
          begin
            $file_logger.info("Request #{request_id}: Starting wait for product cards with timeout #{get_timeout(45000)}ms")
            start_time = Time.now
            search_page.wait_for_selector('.product-card__product', timeout: get_timeout(45000))
            wait_time = Time.now - start_time
            $file_logger.info("Request #{request_id}: Product card(s) found after #{wait_time.round(2)}s")
            
            # Additional check for actual product cards
            product_count = search_page.evaluate(<<~JS)
              () => document.querySelectorAll('.product-card__product').length
            JS
            $file_logger.info("Request #{request_id}: Found #{product_count} product cards")
            
            # Get detailed information about the found card(s)
            $file_logger.info("Request #{request_id}: Starting card details extraction")
            start_time = Time.now
            card_details = search_page.evaluate(<<~JS)
              () => {
                const cards = Array.from(document.querySelectorAll('.product-card__product'));
                return cards.map(card => {
                  const title = card.querySelector('.product-card__title')?.textContent?.trim() || 'No title found';
                  const price = card.querySelector('.inventory__price-with-shipping, .product-card__price, .price-point__price, [data-testid="product-price"]')?.textContent?.trim() || 'No price found';
                  const set = card.querySelector('.product-card__set, .product-card__set-name, [data-testid="product-set"]')?.textContent?.trim() || 'No set found';
                  return { title, price, set };
                });
              }
            JS
            extraction_time = Time.now - start_time
            $file_logger.info("Request #{request_id}: Card details extraction completed in #{extraction_time.round(2)}s")
            if ENV['RACK_ENV'] == 'development'
              $file_logger.debug("Request #{request_id}: Card details: #{JSON.pretty_generate(card_details)}")
            end
            
            # If we found a card but no price, wait a bit longer and try again
            if card_details.any? { |card| card['price'] == 'No price found' }
              $file_logger.info("Request #{request_id}: Found card but no price, waiting additional 2 seconds...")
              sleep(2)
              
              # Try one more time after waiting with updated selectors
              card_details = search_page.evaluate(<<~JS)
                () => {
                  const cards = Array.from(document.querySelectorAll('.product-card__product'));
                  return cards.map(card => {
                    // Try to find the price with the specific inventory class first
                    const priceElement = card.querySelector('.inventory__price-with-shipping, .product-card__price, .price-point__price, [data-testid="product-price"]');
                    const setElement = card.querySelector('.product-card__set, .product-card__set-name, [data-testid="product-set"]');
                    
                    // Log all elements with price in their class name for debugging
                    const allPriceElements = Array.from(card.querySelectorAll('[class*="price"]')).map(el => ({
                      class: el.className,
                      text: el.textContent.trim(),
                      html: el.outerHTML
                    }));
                    
                    return {
                      title: card.querySelector('.product-card__title')?.textContent?.trim() || 'No title found',
                      price: priceElement?.textContent?.trim() || 'No price found',
                      set: setElement?.textContent?.trim() || 'No set found',
                      priceHtml: priceElement?.outerHTML || 'not found',
                      setHtml: setElement?.outerHTML || 'not found',
                      allPriceElements
                    };
                  });
                }
              JS
              if ENV['RACK_ENV'] == 'development'
                $file_logger.debug("Request #{request_id}: Card details after additional wait: #{JSON.pretty_generate(card_details)}")
              end
            end
            
            # Additional check for any potential redirects or search refinements
            page_info = search_page.evaluate(<<~JS)
              () => ({
                currentUrl: window.location.href,
                searchRefinement: document.querySelector('.search-refinement')?.textContent.trim(),
                searchResultsHeader: document.querySelector('.search-results__header')?.textContent.trim(),
                searchResultsCount: document.querySelector('.search-results__count')?.textContent.trim()
              })
            JS
            if ENV['RACK_ENV'] == 'development'
              $file_logger.debug("Request #{request_id}: Page information: #{JSON.pretty_generate(page_info)}")
            end
          rescue => e
            $file_logger.error("Request #{request_id}: Error waiting for product card(s): #{e.message}")
            raise
          end

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
        
        # Get set variant information for the chosen card
        set_variant_info = search_page.evaluate(<<~JS)
          function() {
            const card = document.querySelector('.product-card__product');
            if (!card) return null;
            
            const setVariantElement = card.querySelector('.product-card__set-name__variant');
            return {
              text: setVariantElement ? setVariantElement.textContent.trim() : 'No set variant found',
              html: setVariantElement ? setVariantElement.outerHTML : 'No set variant element found'
            };
          }
        JS

        $file_logger.info("Request #{request_id}: Found lowest priced product: #{lowest_priced_product['title']} at $#{lowest_priced_product['price']}")
        $file_logger.info("Request #{request_id}: Set Variant: #{set_variant_info['text']}")
        $file_logger.info("Request #{request_id}: Set Variant Element: #{set_variant_info['html']}")
        
        # Process just this condition since we're already on the right page
        price = process_single_condition(condition, lowest_priced_product, context, request_id)
        return format_error_response('No valid prices found', legality) unless price
        
        { condition => price }.to_json
      ensure
        if search_page && !search_page.closed?
          begin
            search_page.close
          rescue => e
            # If the page is already closed (or an error occurs), log a debug message instead of an error.
            $file_logger.debug("Request #{request_id}: Skipping close (page already closed or error: #{e.message})")
          end
        end
      end
    end

    def setup_search_page(context, request_id)
      search_page = context.new_page
      PageManager.configure_page(search_page, request_id)
      
      # Inject environment variable into JavaScript context
      search_page.evaluate(<<~JS)
        window.RUBY_ENV = '#{ENV['RACK_ENV']}';
      JS
      
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
        
        # Use the exact URL from the search result
        product_url = lowest_priced_product['url']
        $file_logger.info("Request #{request_id}: Navigating to product page: #{product_url}")
        
        # Use a more lenient wait condition and add error handling
        begin
          condition_page.goto(product_url, 
            wait_until: 'domcontentloaded',  # Changed from networkidle0 to be more lenient
            timeout: get_navigation_timeout
          )
          
          # Log the page state after navigation
          page_state = condition_page.evaluate(<<~JS)
            function() {
              return {
                url: window.location.href,
                title: document.title,
                readyState: document.readyState,
                hasListings: !!document.querySelector('.listing-item'),
                hasPrice: !!document.querySelector('.listing-item__listing-data__info__price'),
                hasShipping: !!document.querySelector('.shipping-messages__price'),
                bodyContent: document.body.textContent.slice(0, 500) + '...'
              };
            }
          JS
          $file_logger.info("Request #{request_id}: Product page state: #{page_state.inspect}")
          
          # Wait a bit for dynamic content
          wait_time = get_timeout(5)
          $file_logger.info("Request #{request_id}: Waiting #{wait_time} seconds for dynamic content...")
          sleep(wait_time)
          
        rescue => e
          $file_logger.error("Request #{request_id}: Error navigating to product page: #{e.message}")
          $file_logger.error("Request #{request_id}: Navigation error details: #{e.backtrace.join("\n")}")
          return nil
        end
        
        PriceExtractor.add_redirect_prevention(condition_page, request_id)
        
        # Try to extract prices with retries
        max_retries = 3
        retry_count = 0
        result = nil
        
        while retry_count < max_retries
          result = PriceExtractor.extract_listing_prices(condition_page, request_id)
          $file_logger.info("Request #{request_id}: Condition result (attempt #{retry_count + 1}): #{result.inspect}")
          
          if result && result.is_a?(Hash) && result['success']
            break
          end
          
          retry_count += 1
          if retry_count < max_retries
            wait_time = get_timeout(2)
            $file_logger.info("Request #{request_id}: Retrying in #{wait_time} seconds...")
            sleep(wait_time)
          end
        end
        
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
        begin
          condition_page.close
        rescue => e
          $file_logger.debug("Request #{request_id}: Error closing condition page: #{e.message}")
        end
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