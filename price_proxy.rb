require 'sinatra'
require 'sinatra/cross_origin'
require 'httparty'
require 'nokogiri'
require 'json'
require 'puppeteer-ruby'
require 'concurrent'  # For parallel processing
require 'tmpdir'
require 'fileutils'
require 'logger'
require 'uri'
require 'securerandom'

set :port, 4567
set :bind, '0.0.0.0'
set :public_folder, 'commander_cards'

# Set up logging first
LOG_FILE = 'price_proxy.log'
File.delete(LOG_FILE) if File.exist?(LOG_FILE)  # Clear log at start
$logger = Logger.new(LOG_FILE)
$logger.level = Logger::INFO  # Only show INFO and above
$logger.formatter = proc do |severity, datetime, progname, msg|
  # Skip certain non-critical warnings
  if severity == 'WARN' && msg.is_a?(String)
    # List of warning messages we want to suppress
    suppressed_warnings = [
      'Frame not found during evaluation',
      'Protocol error',
      'Target closed',
      'Target destroyed',
      'No target with given id found',
      'Frame was detached',
      'Frame was removed',
      'Frame was not found'
    ]
    
    # Skip if this is a suppressed warning
    return nil if suppressed_warnings.any? { |w| msg.include?(w) }
  end
  
  # Truncate everything after the error message when it contains a Ruby object dump
  formatted_msg = if msg.is_a?(String)
    if msg.include?('#<')
      # Keep everything up to and including the error message, then add truncation
      msg.split(/#</).first.strip + " ...truncated..."
    else
      msg
    end
  else
    msg.to_s.split(/#</).first.strip + " ...truncated..."
  end
  
  # Only log if we haven't suppressed the message
  "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{formatted_msg}\n" if formatted_msg
end
$logger.info("=== Starting new price proxy server session ===")
$logger.info("Log file cleared and initialized")

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
          page.client.send_message('Emulation.setDeviceMetricsOverride', {
            width: 3000,
            height: 2000,
            deviceScaleFactor: 1,
            mobile: false
          })
          
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
          page.set_default_navigation_timeout(30000)  # 30 seconds
          page.set_default_timeout(30000)  # 30 seconds
          
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
          $logger.info("New page viewport after resize: #{actual_viewport.inspect}")
        rescue => e
          $logger.error("Error setting up new page: #{e.message}")
        end
      end
    end

    # Create a test page to resize the browser
    test_page = $browser.new_page
    begin
      # Use CDP to set a large viewport
      test_page.client.send_message('Emulation.setDeviceMetricsOverride', {
        width: 3000,
        height: 2000,
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
    width: 1920,
    height: 1080,
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
    $logger.info("\nShutting down gracefully...")
    cleanup_browser  # This is fine as it's not called from within a mutex lock
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

# Get both card legality and prices in a single request
get '/card_info' do
  content_type :json
  card_name = params['card']
  request_id = SecureRandom.uuid
  $logger.info("Starting card info request #{request_id} for: #{card_name}")
  
  if card_name.nil? || card_name.empty?
    $logger.error("No card name provided")
    return { error: 'No card name provided' }.to_json
  end

  # Check if this card is already being processed
  cached_request = $active_requests[card_name]
  if cached_request
    if cached_request[:status] == 'complete'
      $logger.info("Returning cached response for #{card_name}")
      return cached_request[:data]
    elsif cached_request[:status] == 'error'
      $logger.info("Returning cached error for #{card_name}")
      return cached_request[:data]
    end
  end

  # Mark as in progress
  $active_requests[card_name] = { 
    status: 'in_progress', 
    timestamp: Time.now,
    data: nil,
    request_id: request_id
  }

  begin
    # Get legality from Scryfall first
    begin
      $logger.info("Request #{request_id}: Checking legality with Scryfall")
      legality_response = HTTParty.get("https://api.scryfall.com/cards/named?exact=#{CGI.escape(card_name)}")
      if legality_response.success?
        legality_data = JSON.parse(legality_response.body)
        legality = legality_data['legalities']&.fetch('commander', 'unknown')
        $logger.info("Request #{request_id}: Legality for #{card_name}: #{legality}")
      else
        $logger.error("Request #{request_id}: Scryfall API error: #{legality_response.code} - #{legality_response.body}")
        legality = 'unknown'
      end
    rescue => e
      $logger.error("Request #{request_id}: Error checking legality: #{e.message}")
      legality = 'unknown'
    end

    # Get or initialize browser and create context
    browser = get_browser
    context = create_browser_context(request_id)
    
    begin
      # Create a new page for the search
      search_page = context.new_page
      $browser_contexts[request_id][:pages] << search_page
      
      # Enable request interception to prevent redirects
      search_page.request_interception = true
      search_page.on('request') do |request|
        # Add proper headers for TCGPlayer
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
      
      # Set up console log capture
      search_page.on('console') do |msg|
        $logger.info("Request #{request_id}: Browser console: #{msg.text}")
      end
      
      # Navigate to TCGPlayer search
      $logger.info("Request #{request_id}: Navigating to TCGPlayer search for: #{card_name}")
      search_url = "https://www.tcgplayer.com/search/magic/product?q=#{CGI.escape(card_name)}&view=grid"
      $logger.info("Request #{request_id}: Search URL: #{search_url}")
      
      begin
        response = search_page.goto(search_url, wait_until: 'networkidle0')
        $logger.info("Request #{request_id}: Search page response status: #{response.status}")
        
        # Wait for the search results to load
        begin
          search_page.wait_for_selector('.search-result, .product-card, [class*="product"], [class*="listing"]', timeout: 10000)
          $logger.info("Request #{request_id}: Search results found")
        rescue => e
          $logger.error("Request #{request_id}: Timeout waiting for search results: #{e.message}")
          # Take a screenshot for debugging
          screenshot_path = "search_error_#{Time.now.to_i}.png"
          search_page.screenshot(path: screenshot_path)
          $logger.info("Request #{request_id}: Saved error screenshot to #{screenshot_path}")
        end
        
        # Give extra time for dynamic content to stabilize
        sleep(2)
        
        # Log the page content for debugging
        $logger.info("Request #{request_id}: Page title: #{search_page.title}")
        $logger.info("Request #{request_id}: Current URL: #{search_page.url}")
        
        # Find the lowest priced valid product from the search results
        card_name = card_name.strip  # Normalize the card name in Ruby first
        lowest_priced_product = search_page.evaluate(<<~'JS', { cardName: card_name }.to_json)
          function(params) {
            const cardName = JSON.parse(params).cardName;
            console.log('Searching for card:', cardName);
            
            function extractNumericPrice(priceText) {
              if (!priceText) {
                console.log('No price text provided');
                return null;
              }
              
              // Create and inspect the regex object
              const priceRegex = /\$\d+\.\d{2}/;  // Simple match for $XX.XX
              
              // Test if the price matches the pattern
              if (!priceRegex.test(priceText)) {
                console.log('No price pattern found in:', priceText);
                return null;
              }
              
              // Extract just the numeric part (remove the $ sign)
              const numericStr = priceText.slice(1);
              const result = parseFloat(numericStr);
              console.log('Extracted numeric price:', result, 'from:', numericStr);
              return isNaN(result) ? null : result;
            }

            function isExactCardMatch(title, cardName) {
              if (!title || !cardName) {
                console.log('Missing title or cardName:', { title, cardName });
                return false;
              }
              
              // Normalize both strings
              const normalizedTitle = title.toLowerCase().trim().replace(/\s+/g, ' ');
              const normalizedCardName = String(cardName).toLowerCase().trim().replace(/\s+/g, ' ');
              
              console.log('Comparing card names:', {
                normalizedTitle,
                normalizedCardName,
                titleLength: normalizedTitle.length,
                cardNameLength: normalizedCardName.length
              });
              
              // First try exact match
              if (normalizedTitle === normalizedCardName) {
                console.log('Found exact match');
                return true;
              }
              
              // Then try match with punctuation delimiters
              const regex = new RegExp(
                `(^|\\s|[^a-zA-Z0-9])${normalizedCardName}(\\s|[^a-zA-Z0-9]|$)`,
                'i'
              );
              
              const isMatch = regex.test(normalizedTitle);
              console.log('Regex match result:', { 
                isMatch,
                matchIndex: normalizedTitle.search(regex),
                title: normalizedTitle
              });
              
              return isMatch;
            }

            // Wait for elements to be fully loaded
            function waitForElements() {
              return new Promise((resolve) => {
                let attempts = 0;
                const maxAttempts = 50; // 5 seconds total
                
                const checkElements = () => {
                  attempts++;
                  const cards = document.querySelectorAll('.product-card__product');
                  console.log(`Attempt ${attempts}: Found ${cards.length} cards`);
                  
                  if (cards.length > 0) {
                    // Check if any card has content
                    const hasContent = Array.from(cards).some(card => {
                      const title = card.querySelector('.product-card__title');
                      const hasTitle = title && title.textContent.trim().length > 0;
                      if (hasTitle) {
                        console.log('Found card with title:', title.textContent.trim());
                      }
                      return hasTitle;
                    });
                    
                    if (hasContent) {
                      console.log('Found cards with content, waiting for stability...');
                      // Give extra time for dynamic content to stabilize
                      setTimeout(() => {
                        console.log('Content should be stable now');
                        resolve(true);
                      }, 1000);
                      return;
                    }
                  }
                  
                  if (attempts >= maxAttempts) {
                    console.log('Max attempts reached, proceeding anyway');
                    resolve(false);
                    return;
                  }
                  
                  console.log('Waiting for cards with content...');
                  setTimeout(checkElements, 100);
                };
                
                checkElements();
              });
            }

            async function processCards() {
              // Wait for elements to be loaded
              const elementsLoaded = await waitForElements();
              if (!elementsLoaded) {
                console.log('Warning: Elements may not be fully loaded');
              }
              
              // Get all product cards
              const productCards = Array.from(document.querySelectorAll('.product-card__product'));
              console.log(`Found ${productCards.length} product cards`);

              // Process each product card
              const validProducts = productCards.map((card, index) => {
                console.log(`\nProcessing card ${index + 1}:`);
                
                // Get elements using multiple possible selectors
                const titleElement = card.querySelector('.product-card__title') || 
                                   card.querySelector('[class*="title"]') ||
                                   card.querySelector('[class*="name"]');
                const priceElement = card.querySelector('.inventory__price-with-shipping') || 
                                   card.querySelector('[class*="price"]');
                const linkElement = card.querySelector('a[href*="/product/"]') || 
                                  card.closest('a[href*="/product/"]');

                // Log detailed element info
                console.log('Element details:', {
                  title: titleElement ? {
                    exists: true,
                    className: titleElement.className,
                    textContent: titleElement.textContent,
                    innerText: titleElement.innerText,
                    innerHTML: titleElement.innerHTML,
                    textLength: titleElement.textContent.length
                  } : 'Not found',
                  price: priceElement ? {
                    exists: true,
                    className: priceElement.className,
                    textContent: priceElement.textContent,
                    innerText: priceElement.innerText,
                    innerHTML: priceElement.innerHTML,
                    textLength: priceElement.textContent.length
                  } : 'Not found',
                  link: linkElement ? {
                    exists: true,
                    href: linkElement.href
                  } : 'Not found'
                });

                if (!titleElement || !priceElement) {
                  console.log('Missing required elements:', {
                    hasTitle: !!titleElement,
                    hasPrice: !!priceElement,
                    hasLink: !!linkElement
                  });
                  return null;
                }

                // Get the text content with fallbacks
                const title = titleElement.textContent.trim() || 
                            titleElement.innerText.trim() || 
                            titleElement.innerHTML.trim();
                const priceText = priceElement.textContent.trim() || 
                                priceElement.innerText.trim() || 
                                priceElement.innerHTML.trim();
                
                console.log('Extracted text content:', {
                  title,
                  priceText,
                  titleLength: title.length,
                  priceTextLength: priceText.length,
                  titleElementType: titleElement.tagName,
                  priceElementType: priceElement.tagName
                });

                if (!title || !priceText) {
                  console.log('Empty text content:', {
                    titleEmpty: !title,
                    priceTextEmpty: !priceText,
                    titleElementHTML: titleElement.outerHTML,
                    priceElementHTML: priceElement.outerHTML
                  });
                  return null;
                }

                const price = extractNumericPrice(priceText);
                const url = linkElement ? linkElement.href : null;

                // Skip art cards and proxies
                if (title.toLowerCase().includes('art card') || 
                    title.toLowerCase().includes('proxy') ||
                    title.toLowerCase().includes('playtest')) {
                  console.log('Skipping non-playable card:', title);
                  return null;
                }

                const isMatch = isExactCardMatch(title, cardName);
                const hasValidPrice = !isNaN(price) && price > 0;
                
                if (isMatch && hasValidPrice) {
                  console.log('Found valid product:', { 
                    title, 
                    price, 
                    url,
                    isMatch,
                    hasValidPrice
                  });
                  return { title, price, url };
                } else {
                  console.log('Invalid product:', { 
                    title, 
                    price, 
                    isMatch,
                    hasValidPrice,
                    reason: !isMatch ? 'title does not match' : 'invalid price'
                  });
                  return null;
                }
              }).filter(Boolean);

              console.log(`Found ${validProducts.length} valid products`);

              if (validProducts.length === 0) {
                console.log('No valid products found');
                return null;
              }

              // Sort by price and return the lowest priced product
              validProducts.sort((a, b) => a.price - b.price);
              const lowest = validProducts[0];
              console.log('Selected lowest priced product:', lowest);
              return lowest;
            }

            // Execute the async function
            return processCards();
          }
        JS
        
        if !lowest_priced_product
          $logger.error("Request #{request_id}: No valid products found for: #{card_name}")
          return { error: 'No valid product found', legality: legality }.to_json
        end
        
        $logger.info("Request #{request_id}: Found lowest priced product: #{lowest_priced_product['title']} at $#{lowest_priced_product['price']}")
        
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
          condition_page.default_navigation_timeout = 30000  # 30 seconds
          condition_page.default_timeout = 30000  # 30 seconds
          
          # Enable request interception for condition page too
          condition_page.request_interception = true
          condition_page.on('request') do |request|
            # Add proper headers for TCGPlayer
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
          
          begin
            $logger.info("Request #{request_id}: Processing condition: #{condition}")
            result = process_condition(condition_page, lowest_priced_product['url'], condition, request_id, card_name)
            $logger.info("Request #{request_id}: Condition result: #{result.inspect}")
            if result
              prices[condition] = {
                'price' => result['price'],
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
          $logger.error("Request #{request_id}: No valid prices found for any condition")
          return { error: 'No valid prices found', legality: legality }.to_json
        end
        
        $logger.info("Request #{request_id}: Final prices: #{prices.inspect}")
        # Format the response to match the original style
        formatted_prices = {}
        prices.each do |condition, data|
          # Extract just the numeric price from the price text
          price_value = data['price'].gsub(/[^\d.]/, '')
          formatted_prices[condition] = {
            'price' => price_value,
            'url' => data['url']
          }
        end
        
        # Combine prices and legality into a single response
        response = { 
          prices: formatted_prices,
          legality: legality
        }.to_json
        
        # Cache the response with timestamp
        $active_requests[card_name] = { 
          status: 'complete',
          data: response,
          timestamp: Time.now,
          request_id: request_id
        }
        
        response
        
      ensure
        # Clean up the context and its pages
        if context
          begin
            # Close all pages in the context
            if $browser_contexts[request_id]
              $browser_contexts[request_id][:pages].each do |page|
                begin
                  page.close
                rescue => e
                  $logger.error("Request #{request_id}: Error closing page: #{e.message}")
                end
              end
            end
            
            # Close the context
            context.close
            $logger.info("Request #{request_id}: Closed browser context and pages")
          rescue => e
            $logger.error("Request #{request_id}: Error closing browser context: #{e.message}")
          ensure
            $browser_contexts.delete(request_id)
          end
        end
      end
      
    rescue => e
      $logger.error("Request #{request_id}: Error processing request: #{e.message}")
      $logger.error(e.backtrace.join("\n"))
      error_response = { 
        error: e.message,
        legality: legality  # Include legality even if price check failed
      }.to_json
      
      # Cache the error response
      $active_requests[card_name] = {
        status: 'error',
        data: error_response,
        timestamp: Time.now,
        request_id: request_id
      }
      
      error_response
    ensure
      # Clear old requests (older than 5 minutes)
      $active_requests.delete_if do |_, request|
        request[:timestamp] < (Time.now - 300)  # 5 minutes
      end
      
      # Clean up old contexts (older than 10 minutes)
      $browser_contexts.delete_if do |_, context_data|
        if context_data[:created_at] < (Time.now - 600)  # 10 minutes
          begin
            # Close any remaining pages
            context_data[:pages].each do |page|
              begin
                page.close
              rescue => e
                $logger.error("Error closing stale page: #{e.message}")
              end
            end
            # Close the context
            context_data[:context].close
            true  # Return true to delete the context
          rescue => e
            $logger.error("Error cleaning up stale context: #{e.message}")
            true  # Still return true to delete the context
          end
        else
          false  # Keep contexts that aren't stale
        end
      end
    end
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
    $logger.info("Request #{request_id}: Navigating to filtered URL: #{filtered_url}")
    
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
      
      # Take immediate screenshot of the listings area before any redirects
      immediate_screenshot = "immediate_listings_#{condition}_#{Time.now.to_i}.png"
      page.evaluate(<<~JS)
        function() {
          // Try to find the listings container
          const listingsContainer = document.querySelector('.listing-items, .price-points, [class*="listings"], [class*="prices"]');
          if (listingsContainer) {
            listingsContainer.scrollIntoView({ behavior: 'instant', block: 'center' });
          }
        }
      JS
      page.screenshot(path: immediate_screenshot, full_page: true)
      $logger.info("Request #{request_id}: Saved immediate listings screenshot to #{immediate_screenshot}")
      
      # Check if we were redirected despite prevention
      current_url = page.evaluate('window.location.href')
      if current_url.include?('uhoh')
        $logger.error("Request #{request_id}: Redirect to error page occurred despite prevention")
        screenshot_path = "redirect_error_#{condition}_#{Time.now.to_i}.png"
        page.screenshot(path: screenshot_path)
        $logger.info("Request #{request_id}: Saved redirect error screenshot to #{screenshot_path}")
        return nil
      end
      
      $logger.info("Request #{request_id}: Product page response status: #{response.status}")
      
      # Wait a moment for initial content to load
      sleep(2)
      
      # Scroll to where listings would be and log what we find
      page.evaluate(<<~JS)
        function() {
          // Try to find the listings container or price section
          const listingsContainer = document.querySelector('.listing-items, .price-points, [class*="listings"], [class*="prices"]');
          if (listingsContainer) {
            console.log('Found listings container, scrolling to it');
            listingsContainer.scrollIntoView({ behavior: 'smooth', block: 'center' });
            return {
              foundContainer: true,
              containerClass: listingsContainer.className,
              containerHTML: listingsContainer.innerHTML.substring(0, 500),
              containerRect: listingsContainer.getBoundingClientRect()
            };
          } else {
            // If no specific container found, scroll to main content
            const mainContent = document.querySelector('main') || document.querySelector('#main-content');
            if (mainContent) {
              console.log('No listings container found, scrolling to main content');
              mainContent.scrollIntoView({ behavior: 'smooth', block: 'center' });
              return {
                foundContainer: false,
                mainContentHTML: mainContent.innerHTML.substring(0, 500),
                mainContentRect: mainContent.getBoundingClientRect()
              };
            }
            return { foundContainer: false, error: 'No content found to scroll to' };
          }
        }
      JS
      
      # Log what we found after scrolling
      page_content = page.evaluate(<<~JS)
        function() {
          return {
            url: window.location.href,
            title: document.title,
            readyState: document.readyState,
            viewportHeight: window.innerHeight,
            scrollY: window.scrollY,
            elements: {
              listings: document.querySelectorAll('.listing-item, .price-point').length,
              containers: document.querySelectorAll('[class*="listing"], [class*="price"]').length,
              mainContent: document.querySelector('main') ? 'exists' : 'missing',
              appContent: document.querySelector('#app') ? 'exists' : 'missing'
            },
            // Get all elements that might be related to listings
            possibleElements: {
              'listing-item': document.querySelectorAll('.listing-item').length,
              'price-point': document.querySelectorAll('.price-point').length,
              'product-listing': document.querySelectorAll('.product-listing').length,
              'inventory-item': document.querySelectorAll('.inventory-item').length,
              'product-price': document.querySelectorAll('.product-price').length,
              'inventory__price': document.querySelectorAll('.inventory__price').length,
              'inventory__price-with-shipping': document.querySelectorAll('.inventory__price-with-shipping').length
            },
            // Check for loading states
            loadingStates: {
              'loading-spinner': document.querySelectorAll('.loading-spinner, .spinner, [class*="loading"]').length,
              'skeleton': document.querySelectorAll('[class*="skeleton"]').length,
              'placeholder': document.querySelectorAll('[class*="placeholder"]').length
            }
          };
        }
      JS
      $logger.info("Request #{request_id}: Page content after scroll: #{page_content.inspect}")
      
      # Take screenshot of the scrolled page state
      pre_load_screenshot = "pre_load_#{condition}_#{Time.now.to_i}.png"
      page.screenshot(path: pre_load_screenshot, full_page: true)  # Take full page screenshot
      $logger.info("Request #{request_id}: Saved pre-load screenshot to #{pre_load_screenshot}")
      
      # Wait for key elements to be present, regardless of redirect status
      begin
        # Wait for either the product content or a no-results message
        page.wait_for_selector('.product-details, .no-results-message, .listing-item, [class*="product"]', 
          timeout: 15000,
          visible: true
        )
        
        # Log what we found
        element_state = page.evaluate(<<~JS)
          function() {
            return {
              hasProductDetails: !!document.querySelector('.product-details'),
              hasNoResults: !!document.querySelector('.no-results-message'),
              hasListings: !!document.querySelector('.listing-item'),
              hasProductClass: !!document.querySelector('[class*="product"]'),
              url: window.location.href,
              title: document.title,
              readyState: document.readyState
            };
          }
        JS
        $logger.info("Request #{request_id}: Initial element state: #{element_state.inspect}")
        
        # If we have a no-results message, return early
        if element_state['hasNoResults']
          $logger.info("Request #{request_id}: No results message found")
          return nil
        end
        
        # Take another screenshot after elements are found
        post_load_screenshot = "post_load_#{condition}_#{Time.now.to_i}.png"
        page.screenshot(path: post_load_screenshot)
        $logger.info("Request #{request_id}: Saved post-load screenshot to #{post_load_screenshot}")
        
        # Give extra time for dynamic content
        sleep(2)
        
      rescue => e
        $logger.error("Request #{request_id}: Error waiting for elements: #{e.message}")
        # Take error screenshot
        error_screenshot = "element_error_#{condition}_#{Time.now.to_i}.png"
        page.screenshot(path: error_screenshot)
        $logger.info("Request #{request_id}: Saved error screenshot to #{error_screenshot}")
        return nil
      end
      
      # Log initial page state
      initial_state = page.evaluate(<<~JS)
        function() {
          return {
            url: window.location.href,
            title: document.title,
            readyState: document.readyState,
            hasApp: !!document.querySelector('#app'),
            hasContent: !!document.querySelector('main'),
            scripts: Array.from(document.scripts).map(s => s.src || 'inline'),
            bodyContent: document.body.innerHTML.substring(0, 1000),
            networkRequests: performance.getEntriesByType('resource').map(r => ({
              url: r.name,
              type: r.initiatorType,
              status: r.responseStatus
            }))
          };
        }
      JS
      $logger.info("Request #{request_id}: Initial page state: #{initial_state.inspect}")
      
      # Wait for any dynamic content to load
      sleep(2)
      
      # Log page state after initial load
      post_load_state = page.evaluate(<<~JS)
        function() {
          const app = document.querySelector('#app');
          const main = document.querySelector('main');
          return {
            url: window.location.href,
            title: document.title,
            readyState: document.readyState,
            appContent: app ? app.innerHTML.substring(0, 500) : 'No app element',
            mainContent: main ? main.innerHTML.substring(0, 500) : 'No main element',
            hasListings: !!document.querySelector('.listing-item'),
            hasNoResults: !!document.querySelector('.no-results-message'),
            dynamicContent: {
              listings: document.querySelectorAll('.listing-item').length,
              prices: document.querySelectorAll('[class*="price"]').length,
              containers: document.querySelectorAll('[class*="container"]').length
            }
          };
        }
      JS
      $logger.info("Request #{request_id}: Post-load page state: #{post_load_state.inspect}")
      
      # Take a screenshot before any scrolling
      screenshot_path = "pre_scroll_#{condition}_#{Time.now.to_i}.png"
      
      # First scroll down just enough to see the listing area
      page.evaluate(<<~JS)
        function() {
          // Scroll down a fixed amount that we know will show the card properly
          window.scrollTo(0, 300);  // Scroll down 300px
          // Wait a moment for any dynamic content to load
          return new Promise(resolve => setTimeout(resolve, 1000));
        }
      JS
      
      # Now take the screenshot after scrolling
      page.screenshot(path: screenshot_path)
      $logger.info("Request #{request_id}: Saved pre-scroll screenshot to #{screenshot_path}")
      
      # Execute the scroll function with proper error handling
      begin
        scroll_result = page.evaluate(<<~JS)
          function() {
            return new Promise(async (resolve) => {
              try {
                console.log('Starting simplified scroll operation');
                
                // Get page height
                const height = document.documentElement.scrollHeight;
                console.log('Page height:', height);
                
                // Scroll to bottom and back to top to trigger any lazy loading
                window.scrollTo(0, height);
                await new Promise(r => setTimeout(r, 1000));
                window.scrollTo(0, 0);
                await new Promise(r => setTimeout(r, 1000));
                window.scrollTo(0, height);
                
                // Log what we find
                const listings = document.querySelectorAll('.listing-item, .price-point, [class*="listing"], [class*="price"]');
                console.log('Found listings after scroll:', listings.length);
                
                resolve({
                  success: true,
                  finalScroll: window.scrollY,
                  contentHeight: height,
                  hasListings: listings.length > 0,
                  listingCount: listings.length,
                  listingTexts: Array.from(listings).map(el => el.textContent.trim())
                });
              } catch(e) {
                console.error('Scroll error:', e);
                resolve({
                  success: false,
                  error: e.message,
                  stack: e.stack
                });
              }
            });
          }
        JS
        $logger.info("Request #{request_id}: Scroll operation result: #{scroll_result.inspect}")
        
        # Take a screenshot after scrolling
        screenshot_path = "post_scroll_#{condition}_#{Time.now.to_i}.png"
        page.screenshot(path: screenshot_path)
        $logger.info("Request #{request_id}: Saved post-scroll screenshot to #{screenshot_path}")
        
        # Wait for scroll to complete
        sleep(3)
      rescue => e
        $logger.error("Request #{request_id}: Error during scroll: #{e.message}")
        $logger.error("Request #{request_id}: Scroll error details: #{e.backtrace.join("\n")}")
      end
      
      # Wait specifically for listing items with increased timeout and retry logic
      begin
        max_retries = 3
        retry_count = 0
        found_listings = false
        
        while retry_count < max_retries && !found_listings
          begin
            # Wait for either listing items or a "no results" message
            found_listings = page.wait_for_selector('.listing-item, .no-results-message', timeout: 15000)
            if found_listings
              # Check if we got the no results message
              no_results = page.evaluate(<<~JS)
                document.querySelector('.no-results-message') !== null
              JS
              if no_results
                $logger.info("Request #{request_id}: No listings found for this condition")
                return nil
              end
              break
            end
          rescue => e
            retry_count += 1
            if retry_count < max_retries
              $logger.info("Request #{request_id}: Retry #{retry_count} waiting for listings...")
              sleep(2)
              # Try refreshing the page on retry
              page.reload(wait_until: 'networkidle0')
            else
              raise e
            end
          end
        end
        
        if !found_listings
          raise "Failed to find listings after #{max_retries} retries"
        end
        
        $logger.info("Request #{request_id}: Listing items found")
        
        # Get all listings and their prices
        price_data = page.evaluate(<<~'JS')
          function() {
            // Helper function to safely extract numeric price
            function extractNumericPrice(text) {
              if (!text) return null;
              try {
                // Match price patterns like $1.23, $1,234.56
                const match = text.match(/\$[\d,]+(\.\d{2})?/);
                if (!match) return null;
                // Remove $ and commas, then parse as float
                return parseFloat(match[0].replace(/[$,]/g, ''));
              } catch (e) {
                console.error('Error extracting price:', e);
                return null;
              }
            }

            try {
              // Get all listing items with a more specific selector
              const listings = Array.from(document.querySelectorAll('.listing-item:not(.listing-item--sold-out)'));
              console.log('Found', listings.length, 'active listings');

              if (!listings.length) {
                console.log('No active listings found');
                return null;
              }

              // Process each listing with error handling
              const validListings = listings.map(listing => {
                try {
                  // Get price element with fallback selectors
                  const priceElement = listing.querySelector('.listing-item__listing-data__info__price') || 
                                     listing.querySelector('[class*="price"]');
                  const shippingElement = listing.querySelector('.shipping-messages__price') ||
                                        listing.querySelector('[class*="shipping"]');

                  if (!priceElement) {
                    console.log('No price element found in listing');
                    return null;
                  }

                  // Extract base price
                  const basePrice = extractNumericPrice(priceElement.textContent);
                  if (basePrice === null) {
                    console.log('Invalid base price:', priceElement.textContent);
                    return null;
                  }

                  // Calculate shipping price
                  let shippingPrice = 0;
                  if (shippingElement) {
                    const shippingText = shippingElement.textContent.trim();
                    if (!shippingText.toLowerCase().includes('free shipping')) {
                      const price = extractNumericPrice(shippingText);
                      if (price !== null) {
                        shippingPrice = price;
                      }
                    }
                  }

                  const totalPrice = basePrice + shippingPrice;
                  
                  // Only return listings with valid total price
                  if (isNaN(totalPrice) || totalPrice <= 0) {
                    console.log('Invalid total price:', totalPrice);
                    return null;
                  }

                  return {
                    basePrice,
                    shippingPrice,
                    totalPrice,
                    priceText: priceElement.textContent.trim(),
                    shippingText: shippingElement ? shippingElement.textContent.trim() : 'free shipping'
                  };
                } catch (e) {
                  console.error('Error processing listing:', e);
                  return null;
                }
              }).filter(Boolean)  // Remove null entries
                .sort((a, b) => a.totalPrice - b.totalPrice);

              if (!validListings.length) {
                console.log('No valid listings after processing');
                return null;
              }

              // Get the lowest priced listing
              const lowestListing = validListings[0];
              console.log('Selected lowest listing:', lowestListing);

              return {
                price: `$${lowestListing.totalPrice.toFixed(2)}`,
                url: window.location.href,
                debug: {
                  basePrice: lowestListing.basePrice,
                  shippingPrice: lowestListing.shippingPrice,
                  totalPrice: lowestListing.totalPrice,
                  source: 'lowest_valid_listing',
                  rawText: {
                    price: lowestListing.priceText,
                    shipping: lowestListing.shippingText
                  }
                }
              };
            } catch (e) {
              console.error('Error in price extraction:', e);
              return null;
            }
          }
        JS
        
        if price_data
          $logger.info("Request #{request_id}: Found price data: #{price_data.inspect}")
          return price_data
        else
          $logger.error("Request #{request_id}: No price data found")
          return nil
        end
        
      rescue => e
        $logger.error("Request #{request_id}: Timeout waiting for listing items: #{e.message}")
        
        # Log detailed page content for debugging
        page_content = page.evaluate(<<~'JS')
          function() {
            // Get all elements that might be related to listings
            const possibleListingElements = {
              'listing-item': document.querySelectorAll('.listing-item').length,
              'product-listing': document.querySelectorAll('.product-listing').length,
              'inventory-item': document.querySelectorAll('.inventory-item').length,
              'price-point': document.querySelectorAll('.price-point').length,
              'product-price': document.querySelectorAll('.product-price').length,
              'inventory__price': document.querySelectorAll('.inventory__price').length,
              'inventory__price-with-shipping': document.querySelectorAll('.inventory__price-with-shipping').length
            };
            
            // Get the main content area
            const mainContent = document.querySelector('main') || document.querySelector('#main-content') || document.body;
            
            return {
              url: window.location.href,
              title: document.title,
              possibleListingElements,
              mainContentHTML: mainContent ? mainContent.innerHTML.substring(0, 2000) : 'No main content found',
              bodyClasses: document.body.className,
              readyState: document.readyState,
              // Check for any loading indicators
              loadingIndicators: {
                'loading-spinner': document.querySelectorAll('.loading-spinner, .spinner, [class*="loading"]').length,
                'skeleton': document.querySelectorAll('[class*="skeleton"]').length
              }
            };
          }
        JS
        
        $logger.info("Request #{request_id}: Page content at timeout: #{page_content.inspect}")
        
        # Take a screenshot for debugging
        screenshot_path = "price_error_#{condition}_#{Time.now.to_i}.png"
        page.screenshot(path: screenshot_path)
        $logger.info("Request #{request_id}: Saved error screenshot to #{screenshot_path}")
        return nil
      end
      
    rescue => e
      $logger.error("Request #{request_id}: Error processing condition: #{e.message}")
      $logger.error(e.backtrace.join("\n"))
      return nil
    end
  end
end

# Clean up browser on server shutdown
at_exit do
  cleanup_browser
end

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
    # Wait for the page to be ready
    page.wait_for_load_state('domcontentloaded', timeout: 5000)
    
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

puts "Price proxy server starting on http://localhost:4567"
puts "Note: You need to install Chrome/Chromium for Puppeteer to work" 