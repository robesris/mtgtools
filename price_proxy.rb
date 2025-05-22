require 'sinatra'
require 'sinatra/cross_origin'
require 'puppeteer-ruby'
require 'httparty'
require 'json'
require 'securerandom'
require_relative 'lib/logging'
require_relative 'lib/browser_manager'
require_relative 'lib/price_processor'
require_relative 'lib/price_extractor'
require_relative 'lib/request_tracker'
require_relative 'lib/config'
require_relative 'lib/page_manager'
require_relative 'lib/server_config'
require_relative 'lib/error_handler'

# Initialize server configuration and config before Sinatra settings
ServerConfig.setup

# Configure Sinatra settings
set :port, Config.settings[:port]
set :bind, Config.settings[:bind]
set :public_folder, Config.settings[:public_folder]

# Configure CORS
configure do
  enable :cross_origin
  set :allow_origin, "*"
  set :allow_methods, [:get, :post, :options]
  set :allow_credentials, true
  set :max_age, "1728000"
  set :expose_headers, ['Content-Type']
end

# Set up file logging first
$file_logger = Logging.logger
$file_logger.info("=== Starting new price proxy server session ===")
$file_logger.info("Log file cleared and initialized")

# Now initialize configuration
Config.setup

# Override Puppeteer's internal logging
module Puppeteer
  class Logger
    def warn(message)
      # Only show the first line of WARN messages
      message = message.split("\n").first if message.is_a?(String)
      super(message)
    end
  end
end

# Override Sinatra's default logger to handle WARN messages without backtraces
class Sinatra::Logger
  def warn(message)
    # Only show the first line of WARN messages
    message = message.split("\n").first if message.is_a?(String)
    super(message)
  end
end

# Global browser instance and context tracking
# $browser = nil
# $browser_contexts = Concurrent::Hash.new  # Track active contexts
# $browser_mutex = Mutex.new
# $browser_retry_count = 0
# MAX_RETRIES = 3
# SESSION_TIMEOUT = 1800  # 30 minutes

# Add request tracking with concurrent handling
# $active_requests = Concurrent::Hash.new
# $request_mutex = Mutex.new

# Get or initialize browser
def get_browser
  if $browser.nil? || !$browser.connected?
    $file_logger.info("Initializing new browser instance")
    $browser = Puppeteer.launch(
      headless: true,
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
        '--disable-accelerated-2d-canvas',
        '--disable-gpu',
        '--window-size=1920,1080',
        '--disable-web-security',
        '--disable-features=IsolateOrigins,site-per-process',
        '--disable-features=site-per-process',  # Disable site isolation
        '--disable-features=IsolateOrigins',    # Disable origin isolation
        '--disable-features=CrossSiteDocumentBlocking',  # Disable cross-site blocking
        '--disable-features=CrossSiteDocumentBlockingAlways',  # Disable cross-site blocking
        '--disable-blink-features=AutomationControlled',
        '--disable-automation',
        '--disable-infobars',
        '--lang=en-US,en',
        '--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
      ],
      ignore_default_args: ['--enable-automation']
    )
    
    # Set up global browser settings
    $browser.on('targetcreated') do |target|
      if target.type == 'page'
        begin
          page = target.page
          PageManager.configure_page(page)
          
          # Log the viewport size after setting it
          actual_viewport = page.evaluate(<<~JS)
            function() {
              return {
                windowWidth: window.innerWidth,
                windowHeight: window.innerHeight,
                devicePixelRatio: window.devicePixelRatio,
                screenWidth: window.screen.width,
                screenHeight: window.screen.height,
                viewportWidth: document.documentElement.clientWidth,
                viewportHeight: document.documentElement.clientHeight
              };
            }
          JS
          $file_logger.info("New page viewport after resize: #{actual_viewport.inspect}")
        rescue => e
          $file_logger.error("Error setting up new page: #{e.message}")
        end
      end
    end

    # Create a test page to resize the browser
    test_page = $browser.new_page
    begin
      PageManager.configure_page(test_page)
      
      # Verify the viewport size
      actual_viewport = test_page.evaluate(<<~JS)
        function() {
          return {
            windowWidth: window.innerWidth,
            windowHeight: window.innerHeight,
            devicePixelRatio: window.devicePixelRatio,
            screenWidth: window.screen.width,
            screenHeight: window.screen.height,
            viewportWidth: document.documentElement.clientWidth,
            viewportHeight: document.documentElement.clientHeight
          };
        }
      JS
      $file_logger.info("Browser viewport after resize: #{actual_viewport.inspect}")
    ensure
      test_page.close
    end
  end
  $browser
end

# Add a method to create a new context with proper tracking
def create_browser_context(request_id)
  browser = get_browser
  context = browser.create_incognito_browser_context
  
  # Track the context using BrowserManager
  BrowserManager.track_context(request_id, context)
  
  # Listen for target destruction to track when pages are closed
  context.on('targetdestroyed') do |target|
    if target.type == 'page'
      $file_logger.info("Request #{request_id}: Page destroyed in context")
      # Remove the page from our tracking if it exists
      BrowserManager.remove_page(request_id, target)
    end
  end
  
  # Listen for target creation to track new pages
  context.on('targetcreated') do |target|
    if target.type == 'page'
      begin
        page = target.page
        BrowserManager.add_page(request_id, page)
        $file_logger.info("Request #{request_id}: New page created in context")
      rescue => e
        ErrorHandler.handle_puppeteer_error(e, request_id, "Page creation")
      end
    end
  end
  
  context
end

# Add a method to create a new page with proper settings
def create_page
  browser = get_browser
  page = browser.new_page
  PageManager.configure_page(page)
  page
end

# Add a method to handle rate limiting
def handle_rate_limit(page, request_id)
  begin
    # Check if we're being rate limited using valid DOM selectors
    rate_limit_check = page.evaluate(<<~JS)
    function() {
        // Get all error messages
        const errorMessages = Array.from(document.querySelectorAll('.error-message, .rate-limit-message, [class*="error"], [class*="rate-limit"]'));
        
        // Check if any error message contains rate limit text
        const hasRateLimit = errorMessages.some(element => {
          const text = element.textContent.toLowerCase();
          return text.includes('rate limit') || text.includes('too many requests');
        });
        
        // Check for error pages
        const hasErrorPage = document.querySelector('.error-page, .uhoh-page, [class*="error-page"]') !== null;
        
        return {
          hasRateLimit,
          hasErrorPage,
          currentUrl: window.location.href,
          errorMessages: errorMessages.map(el => el.textContent.trim())
        };
      }
    JS
    
    if rate_limit_check['hasRateLimit'] || rate_limit_check['hasErrorPage']
      $file_logger.warn("Request #{request_id}: Rate limit detected, waiting...")
      $file_logger.info("Request #{request_id}: Error messages found: #{rate_limit_check['errorMessages'].inspect}")
      # Take a longer break if we hit rate limiting
      sleep(rand(10..15))
      # Try refreshing the page
      page.reload(wait_until: 'networkidle0')
      return true
    end
  rescue => e
    $file_logger.error("Request #{request_id}: Error checking rate limit: #{e.message}")
    $file_logger.error("Request #{request_id}: Rate limit check error details: #{e.backtrace.join("\n")}")
  end
  false
end

# Handle shutdown signals
['INT', 'TERM'].each do |signal|
  Signal.trap(signal) do
    $file_logger.info("\nShutting down gracefully...")
    exit
  end
end

# Enable CORS
before do
  response.headers["Access-Control-Allow-Origin"] = "*"
  response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  response.headers["Access-Control-Allow-Headers"] = "Content-Type"
end

# Get both card legality and prices in a single request
get '/card_info' do
  content_type :json
  card_name = params['card']
  request_id = SecureRandom.uuid
  $file_logger.info("Starting card info request #{request_id} for: #{card_name}")
  
  if card_name.nil? || card_name.empty?
    ErrorHandler.handle_puppeteer_error(ArgumentError.new("No card name provided"), request_id, "Validation")
    return { error: 'No card name provided' }.to_json
  end

  # Use RequestTracker to handle request tracking
  tracking_result = RequestTracker.track_request(card_name, request_id)
  if tracking_result[:cached]
    return tracking_result[:data]
  end

  begin
    # Get legality from Scryfall first
    begin
      $file_logger.info("Request #{request_id}: Checking legality with Scryfall")
      legality_response = HTTParty.get("https://api.scryfall.com/cards/named?exact=#{CGI.escape(card_name)}")
      if legality_response.success?
        legality_data = JSON.parse(legality_response.body)
        legality = legality_data['legalities']['commander'] || 'unknown'
        $file_logger.info("Request #{request_id}: Legality for #{card_name}: #{legality}")
      else
        $file_logger.error("Request #{request_id}: Scryfall API error: #{legality_response.code} - #{legality_response.body}")
        legality = 'unknown'
      end
    rescue => e
      $file_logger.error("Request #{request_id}: Error checking legality: #{e.message}")
      legality = 'unknown'
    end

    # Use BrowserManager to get browser and context
    browser = BrowserManager.get_browser
    context = BrowserManager.create_browser_context(request_id)
    
    begin
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
        return { error: 'No valid product found', legality: legality }.to_json
      end
      
      $file_logger.info("Request #{request_id}: Found lowest priced product: #{lowest_priced_product['title']} at $#{lowest_priced_product['price']}")
      
      # Now we only need to process the single lowest-priced product
      found_prices = false
      prices = {}
      found_conditions = 0
      conditions = ['Near Mint', 'Lightly Played']
      
      conditions.each do |condition|
        # Stop if we've found both conditions
        break if found_conditions >= 2
        
        # Create a new page for each condition
        condition_page = context.new_page
        PageManager.configure_page(condition_page, request_id)
        
        begin
          $file_logger.info("Request #{request_id}: Processing condition: #{condition}")
          
          # Navigate to the product page with condition filter
          condition_url = "#{lowest_priced_product['url']}?condition=#{CGI.escape(condition)}"
          condition_page.goto(condition_url, wait_until: 'networkidle0')
          
          # Add redirect prevention
          PriceExtractor.add_redirect_prevention(condition_page, request_id)
          
          # Extract prices from listings
          result = PriceExtractor.extract_listing_prices(condition_page, request_id)
          $file_logger.info("Request #{request_id}: Condition result: #{result.inspect}")
          
          if result && result.is_a?(Hash) && result['success']
            prices[condition] = {
              'price' => result['price'].to_s.gsub(/\$/,''),
              'url' => result['url']
            }
            found_conditions += 1
            found_prices = true
          end
        ensure
          condition_page.close
        end
      end
      
      if prices.empty?
        $file_logger.error("Request #{request_id}: No valid prices found for any condition")
        return { error: 'No valid prices found', legality: legality }.to_json
      end
      
      $file_logger.info("Request #{request_id}: Final prices: #{prices.inspect}")
      # Format the response to match the original style
      formatted_prices = PriceProcessor.format_prices(prices)
      
      # Combine prices and legality into a single response
      response = { 
        prices: formatted_prices,
        legality: legality
      }.to_json
      
      RequestTracker.cache_response(card_name, 'complete', response, request_id)
      response
      
    ensure
      # Clean up the context and its pages using BrowserManager
      BrowserManager.cleanup_context(request_id)
    end
    
  rescue => e
    ErrorHandler.handle_puppeteer_error(e, request_id, "Request processing")
    error_response = { 
      error: e.message,
      legality: legality
    }.to_json
    
    RequestTracker.cache_response(card_name, 'error', error_response, request_id)
    error_response
  end
end

# Process a single condition
def process_condition(page, product_url, condition, request_id, card_name)
  begin
    # Add redirect prevention script using safe_evaluate
    safe_evaluate(page, <<~JS, request_id)
      function() {
        // Store original navigation methods
        const originalPushState = history.pushState;
        const originalReplaceState = history.replaceState;
        
        // Override history methods to prevent redirects to error page
        history.pushState = function(state, title, url) {
          if (typeof url === 'string' && url.includes('uhoh')) {
            console.log('Prevented history push to error page');
            return;
          }
          return originalPushState.apply(this, arguments);
        };

        history.replaceState = function(state, title, url) {
          if (typeof url === 'string' && url.includes('uhoh')) {
            console.log('Prevented history replace to error page');
            return;
          }
          return originalReplaceState.apply(this, arguments);
        };

        // Add navigation listener
        window.addEventListener('beforeunload', (event) => {
          if (window.location.href.includes('uhoh')) {
            console.log('Prevented navigation to error page');
            event.preventDefault();
            event.stopPropagation();
            return false;
          }
        });

        // Add click interceptor for links that might redirect
        document.addEventListener('click', (event) => {
          const link = event.target.closest('a');
          if (link && link.href && link.href.includes('uhoh')) {
            console.log('Prevented click navigation to error page');
            event.preventDefault();
            event.stopPropagation();
                return false;
              }
        }, true);

        console.log('Redirect prevention initialized');
      }
    JS
    
    # Navigate to the product page with condition filter
    condition_param = URI.encode_www_form_component(condition)
    filtered_url = "#{product_url}#{product_url.include?('?') ? '&' : '?'}Condition=#{condition_param}&Language=English"
    $file_logger.info("Request #{request_id}: Navigating to filtered URL: #{filtered_url}")
    
    begin
      # Add random delay before navigation
      sleep(rand(2..4))
      
      # Navigate to the page with redirect prevention
      response = page.goto(filtered_url, 
        wait_until: 'domcontentloaded',
        timeout: 30000
      )
      
      # Check for rate limiting after navigation
      if handle_rate_limit(page, request_id)
        # If we hit rate limiting, try one more time
        sleep(rand(5..10))
        response = page.goto(filtered_url, 
          wait_until: 'domcontentloaded',
          timeout: 30000
        )
      end
      
      # Start screenshot loop and price pattern search
      max_wait_time = 30  # Maximum wait time in seconds
      start_time = Time.now
      screenshot_count = 0
      found_listings = false
      screenshot_interval = 2  # Take a screenshot every 2 seconds
      last_screenshot_time = start_time
      max_screenshots = 3  # Only take 3 screenshots

      # Take initial screenshot immediately after page load
      screenshot_path = "loading_sequence_#{condition}_#{screenshot_count}_#{Time.now.to_i}.png"
      page.screenshot(path: screenshot_path, full_page: true)
      $file_logger.info("Request #{request_id}: Saved initial screenshot to #{screenshot_path}")
      screenshot_count += 1
      last_screenshot_time = Time.now

      # Log our current selectors for the product page
      $file_logger.info("Request #{request_id}: Current product page selectors:")
      $file_logger.info("  Container: .listing-item")
      $file_logger.info("  Base Price: .listing-item__listing-data__info__price")
      $file_logger.info("  Shipping: .shipping-messages__price")

      # Main loop - continue until we hit max screenshots
      while screenshot_count < max_screenshots
        current_time = Time.now
        elapsed = current_time - start_time

        # Take screenshot every 2 seconds
        if (current_time - last_screenshot_time) >= screenshot_interval
          begin
            screenshot_path = "loading_sequence_#{condition}_#{screenshot_count}_#{Time.now.to_i}.png"
            page.screenshot(path: screenshot_path, full_page: true)
            $file_logger.info("Request #{request_id}: Saved screenshot #{screenshot_count} at #{elapsed.round(1)}s")
            screenshot_count += 1
            last_screenshot_time = current_time

            # After taking screenshot, try to log the listings HTML
            begin
              listings_html = page.evaluate(<<~'JS')
                function() {
                  try {
                    // Find all listing items
                    var listingItems = document.querySelectorAll('.listing-item');
                    var listings = [];
                    
                    // First, collect all listings for logging
                    listingItems.forEach(function(item, index) {
                      var basePrice = item.querySelector('.listing-item__listing-data__info__price');
                      var shipping = item.querySelector('.shipping-messages__price');
                      
                      listings.push({
                        index: index,
                        containerClasses: item.className,
                        basePrice: basePrice ? {
                          text: basePrice.textContent.trim(),
                          classes: basePrice.className
                        } : null,
                        shipping: shipping ? {
                          text: shipping.textContent.trim(),
                          classes: shipping.className
                        } : null,
                        html: item.outerHTML
                      });
                    });

                    // Find the "listings" text (case insensitive, handles both singular and plural)
                    var listingsHeader = null;
                    var allElements = document.querySelectorAll("*");
                    for (var i = 0; i < allElements.length; i++) {
                      var el = allElements[i];
                      if (el.textContent && /^[0-9]+\\s+[Ll]isting[s]?$/i.test(el.textContent.trim())) {
                        listingsHeader = el;
                        break;
                      }
                    }

                    // Process first listing for price extraction
                    var priceData = null;
                    if (listingItems.length > 0) {
                      var firstItem = listingItems[0];
                      var basePrice = firstItem.querySelector('.listing-item__listing-data__info__price');
                      var shipping = firstItem.querySelector('.shipping-messages__price');
                      
                      if (basePrice) {
                        var priceText = basePrice.textContent.trim();
                        var priceMatch = priceText.match(/\\$([0-9.]+)/);
                        if (priceMatch) {
                          var price = parseFloat(priceMatch[1]);
                          var shippingText = shipping ? shipping.textContent.trim() : '';
                          var shippingMatch = shippingText.match(/\\$([0-9.]+)/);
                          var shippingPrice = shippingMatch ? parseFloat(shippingMatch[1]) : 0;
                          
                          priceData = {
                            success: true,
                            found: true,
                            price: (price + shippingPrice).toFixed(2),
                            url: window.location.href,  // Use the current URL which is our filtered product page
                            details: {
                              basePrice: price.toFixed(2),
                              shippingPrice: shippingPrice.toFixed(2),
                              shippingText: shippingText
                            }
                          };
                        }
                      }
                    }

                    // Return both the listings data and price data
                    return {
                      success: true,
                      found: true,
                      headerText: listingsHeader ? listingsHeader.textContent : null,
                      listings: listings,
                      priceData: priceData || {
                        success: false,
                        found: false,
                        message: "No valid price found in first listing"
                      }
                    };
                  } catch (e) {
                    console.error('Error processing listing:', e);
                    return { 
                      success: false,
                      found: false, 
                      error: e.toString(),
                      message: "Error evaluating listing",
                      stack: e.stack
                    };
                  }
                }
              JS

              if screenshot_count == 3  # Only log detailed info for the third screenshot
                $file_logger.info("Request #{request_id}: === DETAILED LISTINGS INFO (3rd screenshot) ===")
                if listings_html.is_a?(Hash) && listings_html['success']
                  $file_logger.info("  Found listings header: #{listings_html['headerText']}")
                  $file_logger.info("  === LISTINGS FOUND ===")
                  listings_html['listings'].each do |listing|
                    $file_logger.info("  Listing #{listing['index'] + 1}:")
                    $file_logger.info("    Container Classes: #{listing['containerClasses']}")
                    if listing['basePrice']
                      $file_logger.info("    Base Price: #{listing['basePrice']['text']}")
                      $file_logger.info("    Base Price Classes: #{listing['basePrice']['classes']}")
                    end
                    if listing['shipping']
                      $file_logger.info("    Shipping: #{listing['shipping']['text']}")
                      $file_logger.info("    Shipping Classes: #{listing['shipping']['classes']}")
                    end
                    $file_logger.info("    HTML: #{listing['html']}")
                  end

                  # Log price data if found
                  if listings_html['priceData'] && listings_html['priceData']['success']
                    $file_logger.info("  === PRICE DATA ===")
                    $file_logger.info("    Total Price: $#{listings_html['priceData']['price']}")
                    $file_logger.info("    Base Price: $#{listings_html['priceData']['details']['basePrice']}")
                    $file_logger.info("    Shipping: $#{listings_html['priceData']['details']['shippingPrice']}")
                    $file_logger.info("    Shipping Text: #{listings_html['priceData']['details']['shippingText']}")
                  end
                elsif listings_html.is_a?(Hash) && listings_html['error']
                  $file_logger.error("  Error evaluating listing: #{listings_html['error']}")
                  $file_logger.error("  Stack trace: #{listings_html['stack']}")
                else
                  $file_logger.error("  No valid data found: #{listings_html['message']}")
                end
                $file_logger.info("=== END OF LISTINGS INFO ===")
              end

              # If we found a valid price, return it immediately and break out of the loop
              if listings_html.is_a?(Hash) && listings_html['success'] && listings_html['listings'][0]
                base_price = PriceProcessor.parse_base_price(listings_html['listings'][0]['basePrice']['text'])
                shipping_price = PriceProcessor.calculate_shipping_price(listings_html['listings'][0])
                $file_logger.info("Request #{request_id}: Found valid price: $#{base_price}")
                
                result = {
                  'success' => true,
                  'price' => PriceProcessor.total_price_str(base_price, shipping_price).gsub(/[^\d.]/, ''), # Ensure only numeric string
                  'url' => page.url  # Use the current page URL which is our filtered product page
                }
                $file_logger.info("Request #{request_id}: Breaking out of screenshot loop with price: #{result.inspect}")
                return result  # This will exit both the loop and the process_condition method
              end
            rescue => e
              $file_logger.error("Request #{request_id}: Error evaluating listings HTML: #{e.message}")
              $file_logger.error(e.backtrace.join("\n"))
            end
          rescue => e
            $file_logger.error("Request #{request_id}: Error taking screenshot: #{e.message}")
            # Still increment the counter to ensure we don't get stuck
            screenshot_count += 1
            last_screenshot_time = current_time
          end
        end

        # Small sleep to prevent tight loop
        sleep(0.1)
      end

      # If we get here, we didn't find a valid price in any screenshot
      $file_logger.error("Request #{request_id}: No valid listings found after all screenshots")
      return {
        'success' => false,
        'message' => 'No valid listings found after all screenshots'
      }

    rescue => e
      ErrorHandler.handle_puppeteer_error(e, request_id, "Condition processing")
      return {
        'success' => false,
        'message' => e.message
      }
    end
  end
end

# Clean up browser on server shutdown
# at_exit do
#   cleanup_browser
# end

get '/' do
  send_file File.join(settings.public_folder, 'commander_cards.html')
end

# Serve card images
get '/card_images/:filename' do
  send_file File.join(settings.public_folder, 'card_images', params[:filename])
end

# Serve JavaScript file
get '/card_prices.js' do
  content_type 'application/javascript'
  send_file File.join(settings.public_folder, 'card_prices.js')
end

# Add a method to safely evaluate JavaScript on a page
def safe_evaluate(page, script, request_id = nil)
  begin
    # Wait for the page to be ready using available methods
    page.wait_for_selector('body', timeout: 5000)
    
    # Evaluate the script
    page.evaluate(script)
  rescue Puppeteer::FrameManager::FrameNotFoundError => e
    # Log to file with full details
    $file_logger.warn("Request #{request_id}: Frame not found during evaluation: #{e.message}")
    $file_logger.debug("Request #{request_id}: Frame error details: #{e.backtrace.join("\n")}")
    # Log to console without backtrace
    warn("Request #{request_id}: Frame not found during evaluation: #{e.message}")
    nil
  rescue => e
    # Log to file with full details
    $file_logger.error("Request #{request_id}: Error during page evaluation: #{e.message}")
    $file_logger.debug("Request #{request_id}: Evaluation error details: #{e.backtrace.join("\n")}")
    # Log to console without backtrace
    warn("Request #{request_id}: Error during page evaluation: #{e.message}")
    nil
  end
end

# Add a method to handle Puppeteer errors consistently
def handle_puppeteer_error(e, request_id = nil, context = nil)
  # Log to file with full details
  $file_logger.error("Request #{request_id}: #{context} error: #{e.message}")
  $file_logger.debug("Request #{request_id}: #{context} error details: #{e.backtrace.join("\n")}")
  # Log to console without backtrace
  warn("Request #{request_id}: #{context} error: #{e.message}")
end

# Update error handling in the main request handler
get '/card_info' do
  content_type :json
  card_name = params['card']
  request_id = SecureRandom.uuid
  $file_logger.info("Starting card info request #{request_id} for: #{card_name}")
  
  if card_name.nil? || card_name.empty?
    ErrorHandler.handle_puppeteer_error(ArgumentError.new("No card name provided"), request_id, "Validation")
    return { error: 'No card name provided' }.to_json
  end

  # Use RequestTracker to handle request tracking
  tracking_result = RequestTracker.track_request(card_name, request_id)
  if tracking_result[:cached]
    return tracking_result[:data]
  end

  begin
    # Get legality from Scryfall first
    begin
      $file_logger.info("Request #{request_id}: Checking legality with Scryfall")
      legality_response = HTTParty.get("https://api.scryfall.com/cards/named?exact=#{CGI.escape(card_name)}")
      if legality_response.success?
        legality_data = JSON.parse(legality_response.body)
        legality = legality_data['legalities']['commander'] || 'unknown'
        $file_logger.info("Request #{request_id}: Legality for #{card_name}: #{legality}")
      else
        $file_logger.error("Request #{request_id}: Scryfall API error: #{legality_response.code} - #{legality_response.body}")
        legality = 'unknown'
      end
    rescue => e
      $file_logger.error("Request #{request_id}: Error checking legality: #{e.message}")
      legality = 'unknown'
    end

    # Use BrowserManager to get browser and context
    browser = BrowserManager.get_browser
    context = BrowserManager.create_browser_context(request_id)
    
    begin
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
          return { error: 'No valid product found', legality: legality }.to_json
        end
        
      $file_logger.info("Request #{request_id}: Found lowest priced product: #{lowest_priced_product['title']} at $#{lowest_priced_product['price']}")
        
        # Now we only need to process the single lowest-priced product
        found_prices = false
        prices = {}
        found_conditions = 0
        conditions = ['Near Mint', 'Lightly Played']
        
        conditions.each do |condition|
          # Stop if we've found both conditions
          break if found_conditions >= 2
          
          # Create a new page for each condition
          condition_page = context.new_page
        PageManager.configure_page(condition_page, request_id)
        
        begin
          $file_logger.info("Request #{request_id}: Processing condition: #{condition}")
          
          # Navigate to the product page with condition filter
          condition_url = "#{lowest_priced_product['url']}?condition=#{CGI.escape(condition)}"
          condition_page.goto(condition_url, wait_until: 'networkidle0')
          
          # Add redirect prevention
          PriceExtractor.add_redirect_prevention(condition_page, request_id)
          
          # Extract prices from listings
          result = PriceExtractor.extract_listing_prices(condition_page, request_id)
          $file_logger.info("Request #{request_id}: Condition result: #{result.inspect}")
          
            if result && result.is_a?(Hash) && result['success']
              prices[condition] = {
              'price' => result['price'].to_s.gsub(/\$/,''),
                'url' => result['url']
              }
              found_conditions += 1
              found_prices = true
            end
          ensure
            condition_page.close
          end
        end
        
        if prices.empty?
        $file_logger.error("Request #{request_id}: No valid prices found for any condition")
          return { error: 'No valid prices found', legality: legality }.to_json
        end
        
      $file_logger.info("Request #{request_id}: Final prices: #{prices.inspect}")
        # Format the response to match the original style
      formatted_prices = PriceProcessor.format_prices(prices)
        
        # Combine prices and legality into a single response
        response = { 
          prices: formatted_prices,
          legality: legality
        }.to_json
        
      RequestTracker.cache_response(card_name, 'complete', response, request_id)
        response
        
      ensure
      # Clean up the context and its pages using BrowserManager
      BrowserManager.cleanup_context(request_id)
    end
    
          rescue => e
    ErrorHandler.handle_puppeteer_error(e, request_id, "Request processing")
      error_response = { 
        error: e.message,
      legality: legality
      }.to_json
      
    RequestTracker.cache_response(card_name, 'error', error_response, request_id)
      error_response
  end
end

# Update error handling in process_condition
def process_condition(page, product_url, condition, request_id, card_name)
  begin
    # Add redirect prevention script using safe_evaluate
    safe_evaluate(page, <<~JS, request_id)
      function() {
        // Store original navigation methods
        const originalPushState = history.pushState;
        const originalReplaceState = history.replaceState;
        
        // Override history methods to prevent redirects to error page
        history.pushState = function(state, title, url) {
          if (typeof url === 'string' && url.includes('uhoh')) {
            console.log('Prevented history push to error page');
            return;
          }
          return originalPushState.apply(this, arguments);
        };

        history.replaceState = function(state, title, url) {
          if (typeof url === 'string' && url.includes('uhoh')) {
            console.log('Prevented history replace to error page');
            return;
          }
          return originalReplaceState.apply(this, arguments);
        };

        // Add navigation listener
        window.addEventListener('beforeunload', (event) => {
          if (window.location.href.includes('uhoh')) {
            console.log('Prevented navigation to error page');
            event.preventDefault();
            event.stopPropagation();
            return false;
          }
        });

        // Add click interceptor for links that might redirect
        document.addEventListener('click', (event) => {
          const link = event.target.closest('a');
          if (link && link.href && link.href.includes('uhoh')) {
            console.log('Prevented click navigation to error page');
            event.preventDefault();
            event.stopPropagation();
            return false;
          }
        }, true);

        console.log('Redirect prevention initialized');
      }
    JS
    
    # Navigate to the product page with condition filter
    condition_param = URI.encode_www_form_component(condition)
    filtered_url = "#{product_url}#{product_url.include?('?') ? '&' : '?'}Condition=#{condition_param}&Language=English"
    $file_logger.info("Request #{request_id}: Navigating to filtered URL: #{filtered_url}")
    
    begin
      # Add random delay before navigation
      sleep(rand(2..4))
      
      # Navigate to the page with redirect prevention
      response = page.goto(filtered_url, 
        wait_until: 'domcontentloaded',
        timeout: 30000
      )
      
      # Check for rate limiting after navigation
      if handle_rate_limit(page, request_id)
        # If we hit rate limiting, try one more time
        sleep(rand(5..10))
        response = page.goto(filtered_url, 
          wait_until: 'domcontentloaded',
          timeout: 30000
        )
      end
      
      # Start screenshot loop and price pattern search
      max_wait_time = 30  # Maximum wait time in seconds
      start_time = Time.now
      screenshot_count = 0
      found_listings = false
      screenshot_interval = 2  # Take a screenshot every 2 seconds
      last_screenshot_time = start_time
      max_screenshots = 3  # Only take 3 screenshots

      # Take initial screenshot immediately after page load
      screenshot_path = "loading_sequence_#{condition}_#{screenshot_count}_#{Time.now.to_i}.png"
      page.screenshot(path: screenshot_path, full_page: true)
      $file_logger.info("Request #{request_id}: Saved initial screenshot to #{screenshot_path}")
      screenshot_count += 1
      last_screenshot_time = Time.now

      # Log our current selectors for the product page
      $file_logger.info("Request #{request_id}: Current product page selectors:")
      $file_logger.info("  Container: .listing-item")
      $file_logger.info("  Base Price: .listing-item__listing-data__info__price")
      $file_logger.info("  Shipping: .shipping-messages__price")

      # Main loop - continue until we hit max screenshots
      while screenshot_count < max_screenshots
        current_time = Time.now
        elapsed = current_time - start_time

        # Take screenshot every 2 seconds
        if (current_time - last_screenshot_time) >= screenshot_interval
          begin
            screenshot_path = "loading_sequence_#{condition}_#{screenshot_count}_#{Time.now.to_i}.png"
            page.screenshot(path: screenshot_path, full_page: true)
            $file_logger.info("Request #{request_id}: Saved screenshot #{screenshot_count} at #{elapsed.round(1)}s")
            screenshot_count += 1
            last_screenshot_time = current_time

            # After taking screenshot, try to log the listings HTML
            begin
              listings_html = page.evaluate(<<~'JS')
                function() {
                  try {
                    // Find all listing items
                    var listingItems = document.querySelectorAll('.listing-item');
                    var listings = [];
                    
                    // First, collect all listings for logging
                    listingItems.forEach(function(item, index) {
                      var basePrice = item.querySelector('.listing-item__listing-data__info__price');
                      var shipping = item.querySelector('.shipping-messages__price');
                      
                      listings.push({
                        index: index,
                        containerClasses: item.className,
                        basePrice: basePrice ? {
                          text: basePrice.textContent.trim(),
                          classes: basePrice.className
                        } : null,
                        shipping: shipping ? {
                          text: shipping.textContent.trim(),
                          classes: shipping.className
                        } : null,
                        html: item.outerHTML
                      });
                    });

                    // Find the "listings" text (case insensitive, handles both singular and plural)
                    var listingsHeader = null;
                    var allElements = document.querySelectorAll("*");
                    for (var i = 0; i < allElements.length; i++) {
                      var el = allElements[i];
                      if (el.textContent && /^[0-9]+\\s+[Ll]isting[s]?$/i.test(el.textContent.trim())) {
                        listingsHeader = el;
                        break;
                      }
                    }

                    // Process first listing for price extraction
                    var priceData = null;
                    if (listingItems.length > 0) {
                      var firstItem = listingItems[0];
                      var basePrice = firstItem.querySelector('.listing-item__listing-data__info__price');
                      var shipping = firstItem.querySelector('.shipping-messages__price');
                      
                      if (basePrice) {
                        var priceText = basePrice.textContent.trim();
                        var priceMatch = priceText.match(/\\$([0-9.]+)/);
                        if (priceMatch) {
                          var price = parseFloat(priceMatch[1]);
                          var shippingText = shipping ? shipping.textContent.trim() : '';
                          var shippingMatch = shippingText.match(/\\$([0-9.]+)/);
                          var shippingPrice = shippingMatch ? parseFloat(shippingMatch[1]) : 0;
                          
                          priceData = {
                            success: true,
                            found: true,
                            price: (price + shippingPrice).toFixed(2),
                            url: window.location.href,  // Use the current URL which is our filtered product page
                            details: {
                              basePrice: price.toFixed(2),
                              shippingPrice: shippingPrice.toFixed(2),
                              shippingText: shippingText
                            }
                          };
                        }
                      }
                    }

                    // Return both the listings data and price data
                    return {
                      success: true,
                      found: true,
                      headerText: listingsHeader ? listingsHeader.textContent : null,
                      listings: listings,
                      priceData: priceData || {
                        success: false,
                        found: false,
                        message: "No valid price found in first listing"
                      }
                    };
                  } catch (e) {
                    console.error('Error processing listing:', e);
                    return { 
                      success: false,
                      found: false, 
                      error: e.toString(),
                      message: "Error evaluating listing",
                      stack: e.stack
                    };
                  }
                }
              JS

              if screenshot_count == 3  # Only log detailed info for the third screenshot
                $file_logger.info("Request #{request_id}: === DETAILED LISTINGS INFO (3rd screenshot) ===")
                if listings_html.is_a?(Hash) && listings_html['success']
                  $file_logger.info("  Found listings header: #{listings_html['headerText']}")
                  $file_logger.info("  === LISTINGS FOUND ===")
                  listings_html['listings'].each do |listing|
                    $file_logger.info("  Listing #{listing['index'] + 1}:")
                    $file_logger.info("    Container Classes: #{listing['containerClasses']}")
                    if listing['basePrice']
                      $file_logger.info("    Base Price: #{listing['basePrice']['text']}")
                      $file_logger.info("    Base Price Classes: #{listing['basePrice']['classes']}")
                    end
                    if listing['shipping']
                      $file_logger.info("    Shipping: #{listing['shipping']['text']}")
                      $file_logger.info("    Shipping Classes: #{listing['shipping']['classes']}")
                    end
                    $file_logger.info("    HTML: #{listing['html']}")
                  end

                  # Log price data if found
                  if listings_html['priceData'] && listings_html['priceData']['success']
                    $file_logger.info("  === PRICE DATA ===")
                    $file_logger.info("    Total Price: $#{listings_html['priceData']['price']}")
                    $file_logger.info("    Base Price: $#{listings_html['priceData']['details']['basePrice']}")
                    $file_logger.info("    Shipping: $#{listings_html['priceData']['details']['shippingPrice']}")
                    $file_logger.info("    Shipping Text: #{listings_html['priceData']['details']['shippingText']}")
                  end
                elsif listings_html.is_a?(Hash) && listings_html['error']
                  $file_logger.error("  Error evaluating listing: #{listings_html['error']}")
                  $file_logger.error("  Stack trace: #{listings_html['stack']}")
                else
                  $file_logger.error("  No valid data found: #{listings_html['message']}")
                end
                $file_logger.info("=== END OF LISTINGS INFO ===")
              end

              # If we found a valid price, return it immediately and break out of the loop
              if listings_html.is_a?(Hash) && listings_html['success'] && listings_html['listings'][0]
                base_price = PriceProcessor.parse_base_price(listings_html['listings'][0]['basePrice']['text'])
                shipping_price = PriceProcessor.calculate_shipping_price(listings_html['listings'][0])
                $file_logger.info("Request #{request_id}: Found valid price: $#{base_price}")
                
                result = {
                  'success' => true,
                  'price' => PriceProcessor.total_price_str(base_price, shipping_price).gsub(/[^\d.]/, ''), # Ensure only numeric string
                  'url' => page.url  # Use the current page URL which is our filtered product page
                }
                $file_logger.info("Request #{request_id}: Breaking out of screenshot loop with price: #{result.inspect}")
                return result  # This will exit both the loop and the process_condition method
              end
            rescue => e
              $file_logger.error("Request #{request_id}: Error evaluating listings HTML: #{e.message}")
              $file_logger.error(e.backtrace.join("\n"))
            end
          rescue => e
            $file_logger.error("Request #{request_id}: Error taking screenshot: #{e.message}")
            # Still increment the counter to ensure we don't get stuck
            screenshot_count += 1
            last_screenshot_time = current_time
          end
        end

        # Small sleep to prevent tight loop
        sleep(0.1)
      end

      # If we get here, we didn't find a valid price in any screenshot
      $file_logger.error("Request #{request_id}: No valid listings found after all screenshots")
      return {
        'success' => false,
        'message' => 'No valid listings found after all screenshots'
      }

    rescue => e
      ErrorHandler.handle_puppeteer_error(e, request_id, "Condition processing")
      return {
        'success' => false,
        'message' => e.message
      }
    end
  end
end

# Update error handling in cleanup methods
def cleanup_browser_internal
  # Clean up all active contexts
  $browser_contexts.each do |request_id, context_data|
    begin
      $file_logger.info("Cleaning up browser context for request #{request_id}")
      context_data[:context].close if context_data[:context]
    rescue => e
      ErrorHandler.handle_puppeteer_error(e, request_id, "Context cleanup")
    ensure
      $browser_contexts.delete(request_id)
    end
  end
  
  if $browser
  begin
      $file_logger.info("Cleaning up browser...")
      $browser.close
  rescue => e
      ErrorHandler.handle_puppeteer_error(e, nil, "Browser cleanup")
    ensure
      $browser = nil
      # Force garbage collection
      GC.start
    end
  end
end

# Update page error handling
def setup_page_error_handling(page, request_id)
  page.on('error') do |err|
    ErrorHandler.handle_puppeteer_error(err, request_id, "Page")
  end

  page.on('console') do |msg|
    $file_logger.debug("Browser console: #{msg.text}")
  end
end

puts "Price proxy server starting on http://localhost:4568"
puts "Note: You need to install Chrome/Chromium for Puppeteer to work" 