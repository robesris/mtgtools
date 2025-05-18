require 'sinatra'
require 'sinatra/cross_origin'
require 'httparty'
require 'nokogiri'
require 'json'
require 'puppeteer-ruby'
require 'concurrent'  # For parallel processing
require 'tmpdir'
require 'fileutils'

set :port, 4567
set :bind, '0.0.0.0'
set :public_folder, 'commander_cards'

# Global browser instance
$browser = nil
$browser_mutex = Mutex.new
$browser_retry_count = 0
MAX_RETRIES = 3

# Initialize browser
def init_browser
  return if $browser
  $browser = Puppeteer.launch(
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  )
end

# Cleanup browser
def cleanup_browser
  if $browser
    begin
      $browser.close
    rescue => e
      puts "Error closing browser: #{e.message}"
    ensure
      $browser = nil
    end
  end
end

# Handle shutdown signals
['INT', 'TERM'].each do |signal|
  Signal.trap(signal) do
    puts "\nShutting down gracefully..."
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
  init_browser
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

def get_browser
  $browser_mutex.synchronize do
    begin
      if $browser.nil?
        puts "Browser not available, launching new instance..."
        $browser = launch_browser
        $browser_retry_count = 0
      else
        # Test browser connection by creating a test page
        begin
          test_page = $browser.new_page
          test_page.default_navigation_timeout = 5000
          test_page.default_timeout = 5000
          
          # Navigate to a simple page first
          test_page.goto('about:blank', wait_until: 'domcontentloaded', timeout: 5000)
          sleep(1)  # Wait for page to stabilize
          
          # Try a simple evaluation
          result = test_page.evaluate('() => "test"')
          unless result == "test"
            raise "Browser test evaluation failed"
          end
          
          test_page.close
          puts "Browser connection verified"
        rescue => e
          puts "Browser connection test failed: #{e.message}"
          if $browser_retry_count < MAX_RETRIES
            $browser_retry_count += 1
            puts "Retrying browser launch (attempt #{$browser_retry_count})..."
            begin
              $browser.disconnect if $browser.respond_to?(:disconnect)
            rescue => close_error
              puts "Error disconnecting old browser: #{close_error.message}"
            end
            $browser = launch_browser
          else
            puts "Max retries reached, raising error"
            raise "Failed to maintain browser connection after #{MAX_RETRIES} attempts"
          end
        end
      end
      $browser
    rescue => e
      puts "Critical browser error: #{e.message}"
      raise
    end
  end
end

# Process a single condition
def process_condition(page, product_url, condition)
  puts "Processing #{condition} condition..."
  
  # Add condition to the product URL
  condition_param = URI.encode_www_form_component(condition)
  filtered_url = "#{product_url}&Condition=#{condition_param}"
  
  # Navigate to the filtered product page with retry logic
  retries = 0
  begin
    # Set a longer timeout for navigation
    response = page.goto(filtered_url, wait_until: 'networkidle0', timeout: 30000)
    unless response&.ok?
      puts "Failed to load page for #{condition}: #{response&.status}"
      return nil
    end
    
    # Wait for the page to load
    sleep(2)
    
    # Look for the listing with retry
    first_listing = nil
    3.times do |i|
      first_listing = page.query_selector('.listing-item__listing-data__info')
      break if first_listing
      puts "Retry #{i + 1} waiting for listing..."
      sleep(1)
    end
    return nil unless first_listing
    
    # Get the price with retry
    price_element = nil
    3.times do |i|
      price_element = first_listing.query_selector('.listing-item__listing-data__info__price')
      break if price_element
      puts "Retry #{i + 1} waiting for price element..."
      sleep(1)
    end
    price_text = price_element ? price_element.evaluate('el => el.textContent.trim()') : nil
    return nil unless price_text
    
    # Get the shipping
    shipping = nil
    shipping_divs = first_listing.query_selector_all('div')
    shipping_divs.each do |div|
      text = div.evaluate('el => el.textContent.trim()')
      if text.downcase.include?("shipping")
        shipping = text
        break
      end
    end
    
    # Extract shipping cost
    shipping_cost = if shipping && shipping =~ /\+ \$([\d.]+)/
      $1.to_f
    else
      0.0
    end
    
    # Extract price
    price_value = if price_text && price_text =~ /\$([\d,.]+)/
      $1.gsub(',', '').to_f
    else
      return nil
    end
    
    total = price_value + shipping_cost
    
    # Check for foil
    is_foil = first_listing.evaluate('el => {
      return el.querySelector(".foil") || 
             el.querySelector("[data-testid*=\'foil\']") ||
             el.textContent.toLowerCase().includes("foil");
    }')
    
    # Add foil suffix if needed
    condition_key = is_foil ? "#{condition} Foil" : condition
    
    {
      'price' => price_text,
      'shipping' => shipping,
      'total' => sprintf('$%.2f', total),
      'url' => filtered_url
    }
  rescue => e
    puts "Error processing #{condition}: #{e.message}"
    if retries < 2
      retries += 1
      puts "Retrying #{condition} (attempt #{retries})..."
      sleep(2)
      retry
    end
    nil
  end
end

get '/prices' do
  content_type :json
  
  card_name = params['card']
  return { error: 'No card name provided' }.to_json unless card_name
  
  browser = nil
  context = nil
  pages = []
  
  begin
    puts "Looking up prices for: #{card_name}"
    
    # Get browser instance
    browser = get_browser
    # Use the default context instead of incognito
    context = browser.default_browser_context
    
    # Create main page for search
    main_page = context.new_page
    pages << main_page
    
    # Set a longer timeout for navigation
    main_page.default_navigation_timeout = 30000
    
    # Search by card name
    search_url = "https://www.tcgplayer.com/search/magic/product?q=#{URI.encode_www_form_component(card_name + ' card')}&Language=English&view=grid&productLineName=magic&setName=product&isList=false&isProductNameExact=true"
    
    # Navigate to search page with retry logic
    retries = 0
    begin
      puts "Navigating to search URL: #{search_url}"
      
      # Only log important requests and responses
      main_page.on('request') do |request|
        if request.url.include?('tcgplayer.com/search') || request.url.include?('tcgplayer.com/product')
          puts "\nMaking request to: #{request.url}"
        end
      end
      main_page.on('response') do |response|
        if response.url.include?('tcgplayer.com/search') || response.url.include?('tcgplayer.com/product')
          puts "Response from #{response.url}: #{response.status}"
          if response.status != 200
            puts "Error response headers: #{response.headers.inspect}"
          end
        end
      end
      
      response = main_page.goto(search_url, wait_until: 'networkidle0', timeout: 30000)
      puts "\nSearch page loaded with status: #{response&.status}"
      
      # Only log content if there's an error
      if response&.status != 200
        content = main_page.content
        puts "Error page content: #{content[0..1000]}"
      end
      
      # Check if we got a captcha or error page
      if main_page.url.include?('captcha') || main_page.url.include?('error')
        puts "Got captcha/error page. URL: #{main_page.url}"
        puts "Error page content: #{main_page.content[0..1000]}"
        raise "TCGPlayer returned a captcha or error page"
      end
      
      unless response&.ok?
        puts "Response not OK. Status: #{response&.status}"
        puts "Response headers: #{response&.headers&.inspect}"
        raise "Search failed with status #{response&.status}"
      end
      
      # Take a screenshot for debugging
      screenshot_path = "search_#{card_name.gsub(/\s+/, '_')}.png"
      main_page.screenshot(path: screenshot_path)
      puts "\nSaved search results screenshot to #{screenshot_path}"
      
      # Wait for search results with retry
      search_results = []
      3.times do |i|
        # Wait for all search results to load
        puts "\nLooking for search results (attempt #{i + 1})..."
        main_page.wait_for_selector('.product-card', timeout: 5000)
        
        # Get all search results
        search_results = main_page.query_selector_all('.product-card')
        puts "Found #{search_results.length} potential card listings"
        
        # Log the HTML of the first result for debugging
        if search_results.any?
          first_result = search_results.first
          puts "\nAnalyzing first result structure..."
          puts first_result.evaluate('el => {
            const getElementInfo = (el) => {
              const classes = Array.from(el.classList).join(" ");
              const id = el.id ? `#${el.id}` : "";
              return `${el.tagName.toLowerCase()}${id}.${classes}`;
            };
            
            const walk = (el, depth = 0) => {
              const indent = "  ".repeat(depth);
              let info = `${indent}${getElementInfo(el)}`;
              if (el.textContent.trim()) {
                info += ` (text: "${el.textContent.trim()}")`;
              }
              console.log(info);
              Array.from(el.children).forEach(child => walk(child, depth + 1));
            };
            
            walk(el);
            return "See console for full structure";
          }')
          
          # Also log all elements that might contain prices
          puts "\nLooking for price elements..."
          main_page.evaluate('() => {
            const elements = document.querySelectorAll("[class*=\'price\'], [data-testid*=\'price\']");
            return Array.from(elements).map(el => ({
              selector: el.tagName.toLowerCase() + (el.id ? `#${el.id}` : "") + "." + Array.from(el.classList).join("."),
              text: el.textContent.trim(),
              html: el.outerHTML
            }));
          }').each do |el|
            if el["text"].match?(/\$?\d+\.?\d*/)
              puts "Found price element: #{el["selector"]} with value #{el["text"]}"
            end
          end
        end
        
        break if search_results.any?
        puts "No results found, retrying..."
        sleep(1)
      end
      
      unless search_results.any?
        puts "\nNo search results found. Check screenshot at #{screenshot_path} for details."
        return { error: "No search results found" }.to_json
      end
      
      # Find the lowest priced result
      lowest_price_result = nil
      lowest_price = Float::INFINITY
      
      # Normalize card name for comparison
      normalized_search = card_name.downcase.gsub(/[^a-z0-9]/, '')
      
      search_results.each do |result|
        begin
          # Get the price element with multiple possible selectors
          price_element = result.query_selector('
            .product-card__price,
            .product-card__market-price--value,
            [data-testid="product-price"]
          ')
          if price_element
            price_text = price_element.evaluate('el => el.textContent.trim()')
            puts "\nFound price: #{price_text}"
          end
          next unless price_element
          
          # Extract price text and convert to float
          price_text = price_element.evaluate('el => el.textContent.trim()')
          
          # Try different price formats
          price = nil
          if price_text =~ /\$([\d,.]+)/
            price = $1.gsub(',', '').to_f
          elsif price_text =~ /([\d,.]+)/
            price = $1.gsub(',', '').to_f
          end
          
          if price
            # Get the product name for verification
            name_element = result.query_selector('
              .product-card__title
            ')
            if name_element
              name_text = name_element.evaluate('el => el.textContent.trim()')
              # Normalize the found name for comparison
              normalized_name = name_text.downcase.gsub(/[^a-z0-9]/, '')
              
              # Check if this is the exact card we're looking for
              if normalized_name == normalized_search || 
                 (normalized_name.include?(normalized_search) && 
                  # Additional check to avoid matching set names or other products
                  !name_text.match?(/^(booster|commander|deck|set|collection|bundle|box|pack)/i))
                if price < lowest_price
                  lowest_price = price
                  lowest_price_result = result
                  puts "Found matching card '#{name_text}' at $#{price}"
                end
              else
                # Only log non-matches if they're close
                if normalized_name.include?(normalized_search) || 
                   normalized_search.include?(normalized_name)
                  puts "Skipping similar card '#{name_text}'"
                end
              end
            end
          end
        rescue => e
          puts "\nError processing a search result: #{e.message}"
          next
        end
      end
      
      unless lowest_price_result
        puts "\nNo matching cards found with valid prices. Available cards:"
        search_results.each do |result|
          name_element = result.query_selector('
            .product-card__title
          ')
          if name_element
            name = name_element.evaluate('el => el.textContent.trim()')
            # Only show cards that might be relevant
            normalized_name = name.downcase.gsub(/[^a-z0-9]/, '')
            if normalized_name.include?(normalized_search) || normalized_search.include?(normalized_name)
              puts "- #{name}"
            end
          end
        end
        return { error: "Could not find valid prices for #{card_name}" }.to_json
      end
      
      # Get the product URL from the lowest priced result
      product_url = lowest_price_result.evaluate('el => {
        const link = el.querySelector("a[href*=\'/product/\'], a[href*=\'/p/\']");
        return link ? link.href : null;
      }')
      
      unless product_url
        puts "\nError: Could not find product URL for the selected card"
        return { error: "Could not find product URL" }.to_json
      end
      
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
          puts "Processing condition: #{condition}"
          result = process_condition(condition_page, product_url, condition)
          puts "Condition result: #{result.inspect}"
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
        puts "No valid prices found for any condition"
        return { error: 'No valid prices found' }.to_json
      end
      
      puts "Final prices: #{prices.inspect}"
      # Format the response to match the original style
      formatted_prices = {}
      prices.each do |condition, data|
        formatted_prices[condition] = {
          'text' => "#{condition}: $#{data['price'].gsub(/[^\d.]/, '')}",
          'url' => data['url']
        }
      end
      { prices: formatted_prices }.to_json
      
    rescue => e
      puts "Error in /prices endpoint: #{e.message}"
      puts e.backtrace.join("\n")
      { error: e.message }.to_json
    ensure
      # Clean up all pages
      pages.each do |page|
        begin
          page.close if page
        rescue => e
          puts "Error closing page: #{e.message}"
        end
      end
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

puts "Price proxy server starting on http://localhost:4567"
puts "Note: You need to install Chrome/Chromium for Puppeteer to work" 