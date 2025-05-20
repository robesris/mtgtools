require 'sinatra'
require 'sinatra/cross_origin'
require 'httparty'
require 'nokogiri'
require 'json'
require 'puppeteer-ruby'
require 'concurrent'  # For parallel processing
require 'tmpdir'
require 'fileutils'
require 'uri'
require 'securerandom'
require_relative 'lib/logging'
require_relative 'lib/screenshot_manager'
require_relative 'lib/browser_manager'
require_relative 'lib/request_handler'

set :port, 4567
set :bind, '0.0.0.0'
set :public_folder, 'commander_cards'

# Set up logging
$logger = Logging.setup

# Global browser instance and context tracking
$browser = nil
$browser_contexts = Concurrent::Hash.new  # Track active contexts
$browser_mutex = Mutex.new
$browser_retry_count = 0
MAX_RETRIES = 3
SESSION_TIMEOUT = 1800  # 30 minutes

# Add request tracking with concurrent handling
$active_requests = Concurrent::Hash.new
$request_mutex = Mutex.new

# Cleanup browser without mutex lock
def cleanup_browser_internal
  # Clean up all active contexts
  $browser_contexts.each do |request_id, context_data|
    begin
      $logger.info("Cleaning up browser context for request #{request_id}")
      context_data[:context].close if context_data[:context]
    rescue => e
      $logger.error("Error closing browser context for request #{request_id}: #{e.message}")
    ensure
      $browser_contexts.delete(request_id)
    end
  end
  
  if $browser
    begin
      $logger.info("Cleaning up browser...")
      $browser.close
    rescue => e
      $logger.error("Error closing browser: #{e.message}")
    ensure
      $browser = nil
      # Force garbage collection
      GC.start
    end
  end
end

# Cleanup browser with mutex lock
def cleanup_browser
  $browser_mutex.synchronize do
    cleanup_browser_internal
  end
end

# Get or initialize browser
def get_browser
  if $browser.nil? || !$browser.connected?
    $logger.info("Initializing new browser instance")
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
          
          # Set viewport size for each new page
        #   page.client.send_message('Emulation.setDeviceMetricsOverride', {
        #     width: 750,
        #     height: 1000,
        #     deviceScaleFactor: 1,
        #     mobile: false
        #   })

        #   # Dispatch a window resize event to trigger layout reflow
        #   page.evaluate('window.dispatchEvent(new Event("resize"))')
          
          # Disable frame handling for this page
          page.evaluate(<<~JS)
            function() {
              // Disable iframe creation
              const originalCreateElement = document.createElement;
              document.createElement = function(tagName) {
                if (tagName.toLowerCase() === 'iframe') {
                  console.log('Prevented iframe creation');
                  return null;
                }
                return originalCreateElement.apply(this, arguments);
              };
              
              // Block frame navigation
              window.addEventListener('beforeunload', (event) => {
                if (window !== window.top) {
                  event.preventDefault();
                  event.stopPropagation();
                  return false;
                }
              }, true);
              
              // Block frame creation via innerHTML
              const originalInnerHTML = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
              Object.defineProperty(Element.prototype, 'innerHTML', {
                set: function(value) {
                  if (typeof value === 'string' && value.includes('<iframe')) {
                    console.log('Prevented iframe creation via innerHTML');
                    return;
                  }
                  originalInnerHTML.set.call(this, value);
                },
                get: originalInnerHTML.get
              });
            }
          JS
          
          # Set timeouts for each new page
          page.default_navigation_timeout = 30000  # 30 seconds
          page.default_timeout = 30000  # 30 seconds
          
          # Add a small random delay before each navigation
          page.on('request') do |request|
            if request.navigation_request?
              # Block iframe requests
              if request.frame && request.frame.parent_frame
                $logger.info("Blocking iframe request: #{request.url}")
                request.abort
                next
              end
              sleep(rand(1..3))
            end
          end

          # Add error handling for page crashes
          page.on('error') do |err|
            $logger.error("Page error: #{err.message}")
          end

          # Add console logging
          page.on('console') do |msg|
            $logger.debug("Browser console: #{msg.text}")
          end
          
          # Log the viewport size after setting it
        #   actual_viewport = page.evaluate(<<~JS)
        #     function() {
        #       return {
        #         windowWidth: window.innerWidth,
        #         windowHeight: window.innerHeight,
        #         devicePixelRatio: window.devicePixelRatio,
        #         screenWidth: window.screen.width,
        #         screenHeight: window.screen.height,
        #         viewportWidth: document.documentElement.clientWidth,
        #         viewportHeight: document.documentElement.clientHeight
        #       };
        #     }
        #   JS
        #   $logger.info("New page viewport after resize: #{actual_viewport.inspect}")
        rescue => e
          $logger.error("Error setting up new page: #{e.message}")
        end
      end
    end

    # Create a test page to resize the browser
    test_page = $browser.new_page
    begin
      # Use CDP to set a viewport large enough to see page contents
      test_page.client.send_message('Emulation.setDeviceMetricsOverride', {
        width: 750,
        height: 1000,
        deviceScaleFactor: 1,
        mobile: false
      })
      
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
      $logger.info("Browser viewport after resize: #{actual_viewport.inspect}")
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
  
  # Track the context
  $browser_contexts[request_id] = {
    context: context,
    created_at: Time.now,
    pages: []
  }
  
  # Listen for target destruction to track when pages are closed
  context.on('targetdestroyed') do |target|
    if target.type == 'page'
      $logger.info("Request #{request_id}: Page destroyed in context")
      # Remove the page from our tracking if it exists
      if $browser_contexts[request_id]
        $browser_contexts[request_id][:pages].delete_if { |page| page.target == target }
      end
    end
  end
  
  # Listen for target creation to track new pages
  context.on('targetcreated') do |target|
    if target.type == 'page'
      begin
        page = target.page
        if $browser_contexts[request_id]
          $browser_contexts[request_id][:pages] << page
          $logger.info("Request #{request_id}: New page created in context")
        end
      rescue => e
        $logger.error("Request #{request_id}: Error handling new page: #{e.message}")
      end
    end
  end
  
  context
end

# Add a method to create a new page with proper settings
def create_page
  browser = get_browser
  page = browser.new_page
  
  # Disable frame handling for this page
  page.evaluate(<<~JS)
    function() {
      // Disable iframe creation
      const originalCreateElement = document.createElement;
      document.createElement = function(tagName) {
        if (tagName.toLowerCase() === 'iframe') {
          console.log('Prevented iframe creation');
          return null;
        }
        return originalCreateElement.apply(this, arguments);
      };
      
      // Block frame navigation
      window.addEventListener('beforeunload', (event) => {
        if (window !== window.top) {
          event.preventDefault();
          event.stopPropagation();
          return false;
        }
      }, true);
    }
  JS
  
  # Set viewport for the new page
  page.viewport = Puppeteer::Viewport.new(
    # width: 1920,
    # height: 1080,
    device_scale_factor: 1,
    is_mobile: false,
    has_touch: false,
    is_landscape: true
  )
  
  # Set up page-specific settings
  page.set_default_navigation_timeout(30000)
  page.set_default_timeout(30000)
  
  # Set up request interception
  page.request_interception = true
  
  # Add proper headers for TCGPlayer
  page.on('request') do |request|
    # Block iframe requests
    if request.frame && request.frame.parent_frame
      $logger.info("Blocking iframe request: #{request.url}")
      request.abort
      next
    end
    
    headers = request.headers.merge({
      'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
      'Accept-Language' => 'en-US,en;q=0.9',
      'Accept-Encoding' => 'gzip, deflate, br',
      'Connection' => 'keep-alive',
      'Upgrade-Insecure-Requests' => '1',
      'Sec-Fetch-Dest' => 'document',
      'Sec-Fetch-Mode' => 'navigate',
      'Sec-Fetch-Site' => 'none',
      'Sec-Fetch-User' => '?1',
      'Cache-Control' => 'max-age=0'
    })

    if request.navigation_request? && !request.redirect_chain.empty?
      # Only prevent redirects to error pages
      if request.url.include?('uhoh')
        $logger.info("Request #{request_id}: Preventing redirect to error page: #{request.url}")
        request.abort
      else
        $logger.info("Request #{request_id}: Allowing redirect to: #{request.url}")
        request.continue(headers: headers)
      end
    else
      # Allow all other requests, including API calls
      request.continue(headers: headers)
    end
  end

  # Add error handling
  page.on('error') do |err|
    $logger.error("Page error: #{err.message}")
  end

  # Add console logging
  page.on('console') do |msg|
    $logger.debug("Browser console: #{msg.text}")
  end

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
      $logger.warn("Request #{request_id}: Rate limit detected, waiting...")
      $logger.info("Request #{request_id}: Error messages found: #{rate_limit_check['errorMessages'].inspect}")
      # Take a longer break if we hit rate limiting
      sleep(rand(10..15))
      # Try refreshing the page
      page.reload(wait_until: 'networkidle0')
      return true
    end
  rescue => e
    $logger.error("Request #{request_id}: Error checking rate limit: #{e.message}")
    $logger.error("Request #{request_id}: Rate limit check error details: #{e.backtrace.join("\n")}")
  end
  false
end

# Handle shutdown signals
['INT', 'TERM'].each do |signal|
  Signal.trap(signal) do
    $logger.info("\nReceived #{signal} signal, shutting down gracefully...")
    begin
      BrowserManager.cleanup_browser
      ScreenshotManager.delete_all_screenshots
      $logger.info("Cleanup completed successfully")
    rescue => e
      $logger.error("Error during signal cleanup: #{e.message}")
      $logger.error(e.backtrace.join("\n"))
    end
    exit
  end
end

configure do
  enable :cross_origin
  set :allow_origin, "*"
  set :allow_methods, [:get, :post, :options]
  set :allow_credentials, true
  set :max_age, "1728000"
  set :expose_headers, ['Content-Type']
end

# Enable CORS
before do
  response.headers["Access-Control-Allow-Origin"] = "*"
  response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  response.headers["Access-Control-Allow-Headers"] = "Content-Type"
end

# Load the card search JavaScript
$card_search_js = File.read('lib/js/card_search.js').strip

# Initialize browser on startup
begin
  $logger.info("Initializing browser on startup...")
  $browser = BrowserManager.get_browser
  
  # Expose the card search function to all pages (with error logging)
  $browser.on('targetcreated') do |target|
    if target.type == 'page'
      target.page.then do |page|
        begin
          page.evaluate(<<~JS)
            (function() {
              try {
                 // Define the card search function in the global scope
                 window.cardSearch = #{File.read('lib/js/card_search.js')};
                 console.log("Card search function injected (global)");
              } catch (e) {
                 console.error("Error injecting card search (global):", e);
                 # Re-throw so that the server does not start with a broken browser
                 raise e
              }
            })();
          JS
        rescue => e
          $logger.error("(Ruby) Error injecting card search (global) (page #{page.url}): #{e.message} (stack: #{e.backtrace.join("\n")})");
          # Re-throw so that the server does not start with a broken browser
          raise e
        end
      end
    end
  end
  
  $logger.info("Browser initialized successfully")
rescue => e
  $logger.error("Failed to initialize browser: #{e.message}")
  $logger.error(e.backtrace.join("\n"))
  # Re-throw so that the server does not start with a broken browser
  raise e
end

# Clean up browser on shutdown
at_exit do
  $logger.info("Shutting down server, cleaning up browser...")
  begin
    BrowserManager.cleanup_browser
    ScreenshotManager.delete_all_screenshots
    $logger.info("Cleanup completed successfully")
  rescue => e
    $logger.error("Error during cleanup: #{e.message}")
    $logger.error(e.backtrace.join("\n"))
  end
end

# Serve the main application page
get '/' do
  send_file File.join(settings.public_folder, 'commander_cards.html')
end

# Handle card info requests
post '/card_info' do
  content_type :json
  
  begin
    # Parse request body
    request_body = JSON.parse(request.body.read)
    card_name = request_body['card_name']
    
    if !card_name || card_name.strip.empty?
      return {
        'success' => false,
        'error' => 'No card name provided'
      }.to_json
    end
    
    # Generate request ID for tracking
    request_id = SecureRandom.hex(4)
    $logger.info("Request #{request_id}: Received request for card: #{card_name}")
    
    # Handle the request
    result = RequestHandler.handle_request(card_name, request_id)
    
    # Return the result
    result.to_json
  rescue JSON::ParserError => e
    $logger.error("Invalid JSON in request body: #{e.message}")
    {
      'success' => false,
      'error' => 'Invalid JSON in request body'
    }.to_json
  rescue => e
    $logger.error("Error processing request: #{e.message}")
    $logger.error(e.backtrace.join("\n"))
    {
      'success' => false,
      'error' => "Error processing request: #{e.message}"
    }.to_json
  end
end

# Handle health check requests
get '/health' do
  content_type :json
  {
    'status' => 'ok',
    'timestamp' => Time.now.to_i
  }.to_json
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
    $logger.warn("Request #{request_id}: Frame not found during evaluation: #{e.message}")
    nil
  rescue => e
    $logger.error("Request #{request_id}: Error during page evaluation: #{e.message}")
    nil
  end
end

# Helper method to parse a money-formatted string into cents
def parse_base_price(price_text)
  return 0 unless price_text.is_a?(String)
  
  # Remove any non-numeric characters except decimal point
  numeric_str = price_text.gsub(/[^\d.]/, '')
  return 0 if numeric_str.empty?
  
  # Convert to float and then to cents
  (numeric_str.to_f * 100).round
end

# Helper method to calculate shipping price from a listing hash
def calculate_shipping_price(listing)
  return 0 unless listing.is_a?(Hash)
  return 0 unless listing['shipping'].is_a?(Hash)
  return 0 unless listing['shipping']['text'].is_a?(String)
  
  shipping_text = listing['shipping']['text'].strip.downcase
  
  # Check for free shipping indicators
  return 0 if shipping_text.include?('free shipping') ||
              shipping_text.include?('shipping included') ||
              shipping_text.include?('free shipping over')
  
  # Look for shipping cost pattern
  if shipping_text =~ /\+\s*\$(\d+\.?\d*)\s*shipping/i
    # Convert to cents
    (Regexp.last_match(1).to_f * 100).round
  else
    0
  end
end

# Helper method to format total price as string
def total_price_str(base_price_cents, shipping_price_cents)
  total_cents = base_price_cents + shipping_price_cents
  # Return just the numeric value with 2 decimal places, no dollar sign
  format('%.2f', total_cents / 100.0)
end

puts "Price proxy server starting on http://localhost:4567"
puts "Note: You need to install Chrome/Chromium for Puppeteer to work" 