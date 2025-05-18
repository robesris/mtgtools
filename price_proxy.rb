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

set :port, 4567
set :bind, '0.0.0.0'
set :public_folder, 'commander_cards'

# Set up logging first
LOG_FILE = 'price_proxy.log'
File.delete(LOG_FILE) if File.exist?(LOG_FILE)  # Start fresh each time
$logger = Logger.new(LOG_FILE)
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
end

# Global browser instance
$browser = nil
$browser_mutex = Mutex.new
$browser_retry_count = 0
MAX_RETRIES = 3

# Get or initialize browser
def get_browser
  $browser_mutex.synchronize do
    if $browser.nil?
      $logger.info("Initializing browser...")
      begin
        $browser = Puppeteer.launch(
          headless: false,
          args: ['--no-sandbox', '--disable-setuid-sandbox']
        )
        $logger.info("Browser initialized successfully")
      rescue => e
        $logger.error("Failed to initialize browser: #{e.message}")
        $logger.error(e.backtrace.join("\n"))
        raise
      end
    end
    $browser
  end
end

# Cleanup browser
def cleanup_browser
  $browser_mutex.synchronize do
    if $browser
      begin
        $logger.info("Cleaning up browser...")
        $browser.close
      rescue => e
        $logger.error("Error closing browser: #{e.message}")
      ensure
        $browser = nil
      end
    end
  end
end

# Handle shutdown signals
['INT', 'TERM'].each do |signal|
  Signal.trap(signal) do
    $logger.info("\nShutting down gracefully...")
    cleanup_browser
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

def launch_browser
  puts "Launching new browser instance..."
  
  # Launch browser directly with Puppeteer
  browser = Puppeteer.launch(
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-accelerated-2d-canvas',
      '--disable-gpu',
      '--window-size=1920,1080',
      '--disable-blink-features=AutomationControlled',  # Hide automation
      '--disable-features=IsolateOrigins,site-per-process',  # Disable site isolation
      '--disable-web-security',  # Disable CORS
      '--disable-features=IsolateOrigins,site-per-process,SameSiteByDefaultCookies,CookiesWithoutSameSiteMustBeSecure',  # Disable security features
      '--disable-extensions',  # Disable extensions
      '--disable-component-extensions-with-background-pages',  # Disable background extensions
      '--disable-default-apps',  # Disable default apps
      '--mute-audio',  # Mute audio
      '--no-first-run',  # Skip first run
      '--no-default-browser-check',  # Skip default browser check
      '--disable-background-timer-throttling',  # Disable timer throttling
      '--disable-backgrounding-occluded-windows',  # Disable background throttling
      '--disable-renderer-backgrounding',  # Disable renderer backgrounding
      '--disable-breakpad',  # Disable crash reporting
      '--disable-sync',  # Disable sync
      '--disable-translate',  # Disable translate
      '--metrics-recording-only',  # Only record metrics
      '--disable-hang-monitor',  # Disable hang monitor
      '--disable-prompt-on-repost',  # Disable repost prompt
      '--disable-client-side-phishing-detection',  # Disable phishing detection
      '--password-store=basic',  # Use basic password store
      '--use-mock-keychain',  # Use mock keychain
      '--disable-site-isolation-trials'  # Disable site isolation trials
    ]
  )
  
  # Set a realistic user agent and headers for all new pages
  browser.on('targetcreated') do |target|
    if target.type == 'page'
      begin
        page = target.page
        page.set_user_agent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
        
        # Wait for the page to be ready before injecting scripts
        page.wait_for_load_state('domcontentloaded')
        
        # Override navigator.webdriver to appear as a real browser
        page.evaluate_on_new_document(<<~JS)
          Object.defineProperty(navigator, 'webdriver', {
            get: () => undefined
          });
          // Override other automation detection
          Object.defineProperty(navigator, 'plugins', {
            get: () => [1, 2, 3, 4, 5]
          });
          Object.defineProperty(navigator, 'languages', {
            get: () => ['en-US', 'en']
          });
          // Override more browser properties
          Object.defineProperty(navigator, 'platform', {
            get: () => 'MacIntel'
          });
          Object.defineProperty(navigator, 'vendor', {
            get: () => 'Google Inc.'
          });
          Object.defineProperty(navigator, 'maxTouchPoints', {
            get: () => 5
          });
          Object.defineProperty(navigator, 'hardwareConcurrency', {
            get: () => 8
          });
          Object.defineProperty(navigator, 'deviceMemory', {
            get: () => 8
          });
          Object.defineProperty(navigator, 'connection', {
            get: () => ({
              effectiveType: '4g',
              rtt: 50,
              downlink: 10,
              saveData: false
            })
          });
          // Override window properties
          Object.defineProperty(window, 'chrome', {
            get: () => ({
              runtime: {},
              loadTimes: function() {},
              csi: function() {},
              app: {}
            })
          });
        JS
        
        # Add cookies to appear more like a real browser
        page.set_cookie({
          name: 'tcgplayer_session',
          value: '1',
          domain: '.tcgplayer.com',
          path: '/'
        })
        
        # Add more cookies
        page.set_cookie({
          name: 'tcgplayer_visitor',
          value: '1',
          domain: '.tcgplayer.com',
          path: '/'
        })
        page.set_cookie({
          name: 'tcgplayer_preferences',
          value: '{"currency":"USD","language":"en"}',
          domain: '.tcgplayer.com',
          path: '/'
        })
      rescue => e
        puts "Error setting up new page: #{e.message}"
        # Don't re-raise, just log the error
      end
    end
  end
  
  puts "Browser launched successfully"
  browser
rescue => e
  puts "Error launching browser: #{e.message}"
  raise
end

# Process a single condition
def process_condition(page, product_url, condition)
  begin
    # Navigate to the product page with condition filter
    condition_param = URI.encode_www_form_component(condition)
    filtered_url = "#{product_url}?Condition=#{condition_param}"
    $logger.info("Navigating to filtered URL: #{filtered_url}")
    
    response = page.goto(filtered_url, wait_until: 'networkidle0')
    $logger.info("Product page response status: #{response.status}")
    $logger.info("Product page title: #{page.title}")
    $logger.info("Product page URL: #{page.url}")
    
    # Try multiple selectors for the condition dropdown
    selectors = [
      '.condition-selector',
      '[data-testid="condition-selector"]',
      '.condition-dropdown',
      '[data-testid="condition-dropdown"]',
      'select[name="Condition"]',
      'select[data-testid="condition-select"]',
      'button[aria-label*="condition"]',
      'button[aria-label*="Condition"]'
    ]
    
    found_selector = nil
    selectors.each do |selector|
      begin
        $logger.info("Trying condition selector: #{selector}")
        page.wait_for_selector(selector, timeout: 5000)
        found_selector = selector
        $logger.info("Found working condition selector: #{selector}")
        break
      rescue => e
        $logger.info("Condition selector #{selector} not found: #{e.message}")
      end
    end
    
    unless found_selector
      $logger.error("Could not find any condition selectors")
      # Take a screenshot for debugging
      screenshot_path = "condition_error_#{Time.now.to_i}.png"
      page.screenshot(path: screenshot_path)
      $logger.info("Saved condition error screenshot to #{screenshot_path}")
      return nil
    end
    
    # Click the condition dropdown
    $logger.info("Clicking condition selector: #{found_selector}")
    page.click(found_selector)
    
    # Wait for the dropdown menu and click the condition
    $logger.info("Waiting for condition dropdown menu")
    page.wait_for_selector('.condition-dropdown')
    condition_selector = "//div[contains(@class, 'condition-dropdown')]//div[contains(text(), '#{condition}')]"
    $logger.info("Waiting for condition option: #{condition}")
    page.wait_for_xpath(condition_selector)
    $logger.info("Clicking condition option")
    page.click_xpath(condition_selector)
    
    # Wait a moment for the price to update
    sleep(2)
    
    # Try to get price from both spotlight and regular listings
    price_data = page.evaluate(<<~JAVASCRIPT)
      () => {
        // Try spotlight price first
        const spotlightPrice = document.querySelector('.spotlight__price');
        if (spotlightPrice) {
          return { price: spotlightPrice.textContent.trim(), url: window.location.href };
        }
        
        // Try regular listing price
        const listingPrice = document.querySelector('.listing-item__listing-data__info__price');
        if (listingPrice) {
          return { price: listingPrice.textContent.trim(), url: window.location.href };
        }
        
        // If neither found, try any element with a price
        const allElements = Array.from(document.querySelectorAll('*'));
        const priceElement = allElements.find(el => {
          const text = el.textContent.trim();
          return text.startsWith('$') && !isNaN(parseFloat(text.replace('$', '')));
        });
        
        return priceElement ? { price: priceElement.textContent.trim(), url: window.location.href } : null;
      }
    JAVASCRIPT
    
    unless price_data
      $logger.error("Could not find price")
      # Take a screenshot for debugging
      screenshot_path = "price_error_#{condition}_#{Time.now.to_i}.png"
      page.screenshot(path: screenshot_path)
      $logger.info("Saved price error screenshot to #{screenshot_path}")
      
      # Log all price-related elements for debugging
      all_prices = page.evaluate(<<~JAVASCRIPT)
        () => {
          const elements = Array.from(document.querySelectorAll('*'));
          return elements
            .filter(el => el.textContent.includes('$'))
            .map(el => ({
              text: el.textContent.trim(),
              html: el.outerHTML,
              classes: el.className,
              id: el.id
            }));
        }
      JAVASCRIPT
      $logger.info("Found elements with $: #{all_prices.inspect}")
      
      return nil
    end
    
    $logger.info("Found price data: #{price_data.inspect}")
    return price_data
    
  rescue => e
    $logger.error("Error processing condition #{condition}: #{e.message}")
    $logger.error(e.backtrace.join("\n"))
    # Take a screenshot for debugging
    screenshot_path = "condition_error_#{condition}_#{Time.now.to_i}.png"
    page.screenshot(path: screenshot_path)
    $logger.info("Saved condition error screenshot to #{screenshot_path}")
    return nil
  end
end

get '/prices' do
  content_type :json
  card_name = params['card']
  $logger.info("Processing price request for: #{card_name}")
  
  if card_name.nil? || card_name.empty?
    $logger.error("No card name provided")
    return { error: 'No card name provided' }.to_json
  end

  begin
    # Get or initialize browser
    browser = get_browser
    context = browser.create_incognito_browser_context
    pages = []
    
    begin
      # Create a new page for the search
      search_page = context.new_page
      pages << search_page
      
      search_page.default_navigation_timeout = 30000
      
      # Navigate to TCGPlayer search
      $logger.info("Navigating to TCGPlayer search for: #{card_name}")
      search_url = "https://www.tcgplayer.com/search/magic/product?q=#{CGI.escape(card_name)}&view=grid"
      $logger.info("Search URL: #{search_url}")
      
      response = search_page.goto(search_url, wait_until: 'networkidle0')
      $logger.info("Search page response status: #{response.status}")
      
      # Log the page content for debugging
      $logger.info("Page title: #{search_page.title}")
      $logger.info("Current URL: #{search_page.url}")
      
      # Try multiple selectors for the product grid
      selectors = [
        '.product-grid',
        '.search-result',
        '.product-list',
        '[data-testid="product-grid"]',
        '[data-testid="search-results"]'
      ]
      
      found_selector = nil
      selectors.each do |selector|
        begin
          $logger.info("Trying selector: #{selector}")
          search_page.wait_for_selector(selector, timeout: 5000)
          found_selector = selector
          $logger.info("Found working selector: #{selector}")
          break
        rescue => e
          $logger.info("Selector #{selector} not found: #{e.message}")
        end
      end
      
      unless found_selector
        $logger.error("Could not find any product grid selectors")
        # Take a screenshot for debugging
        screenshot_path = "search_error_#{Time.now.to_i}.png"
        search_page.screenshot(path: screenshot_path)
        $logger.info("Saved error screenshot to #{screenshot_path}")
        return { error: 'Could not find product listings' }.to_json
      end
      
      # Get the first product URL with multiple possible selectors
      product_url = search_page.evaluate(<<~JAVASCRIPT)
        () => {
          // Try different selectors for the product link
          const selectors = [
            '.product-grid a',
            '.search-result a',
            '.product-list a',
            '[data-testid="product-grid"] a',
            '[data-testid="search-results"] a',
            'a[href*="/product/"]',
            'a[href*="/p/"]'
          ];
          
          for (const selector of selectors) {
            const link = document.querySelector(selector);
            if (link && link.href) {
              // Remove any existing query parameters
              const url = new URL(link.href);
              return url.origin + url.pathname;
            }
          }
          return null;
        }
      JAVASCRIPT
      
      if product_url.nil?
        $logger.error("No product found for: #{card_name}")
        # Take a screenshot for debugging
        screenshot_path = "no_product_#{Time.now.to_i}.png"
        search_page.screenshot(path: screenshot_path)
        $logger.info("Saved no-product screenshot to #{screenshot_path}")
        return { error: 'No product found' }.to_json
      end
      
      $logger.info("Found product URL: #{product_url}")
      
      # Process conditions sequentially instead of in parallel
      conditions = ['Lightly Played', 'Near Mint']
      prices = {}
      found_conditions = 0
      
      conditions.each do |condition|
        # Stop if we've found both conditions
        break if found_conditions >= 2
        
        # Create a new page for each condition
        condition_page = context.new_page
        pages << condition_page
        
        condition_page.default_navigation_timeout = 30000
        
        begin
          $logger.info("Processing condition: #{condition}")
          result = process_condition(condition_page, product_url, condition)
          $logger.info("Condition result: #{result.inspect}")
          if result
            # Only include the price and URL in the response, not the shipping info
            prices[condition] = {
              'price' => result['price'],
              'url' => result['url']
            }
            found_conditions += 1
          end
        ensure
          # Don't close the page yet, we'll close all pages at the end
        end
      end
      
      if prices.empty?
        $logger.error("No valid prices found for any condition")
        return { error: 'No valid prices found' }.to_json
      end
      
      $logger.info("Final prices: #{prices.inspect}")
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
      $logger.info("Sending response: #{formatted_prices.inspect}")
      { prices: formatted_prices }.to_json
      
    ensure
      # Close all pages but keep the browser
      pages.each(&:close)
      context.close
    end
    
  rescue => e
    $logger.error("Error processing request: #{e.message}")
    $logger.error(e.backtrace.join("\n"))
    { error: e.message }.to_json
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

puts "Price proxy server starting on http://localhost:4567"
puts "Note: You need to install Chrome/Chromium for Puppeteer to work" 