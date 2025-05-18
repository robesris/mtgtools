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
      '--disable-features=IsolateOrigins,site-per-process'  # Disable site isolation
    ]
  )
  
  # Set a realistic user agent and headers for all new pages
  browser.on('targetcreated', ->(target) {
    if target.type == 'page'
      page = target.page
      page.set_user_agent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
      
      # Override navigator.webdriver to appear as a real browser
      page.add_init_script(<<~JS)
        Object.defineProperty(navigator, 'webdriver', {
          get: () => undefined
        });
      JS
    end
  })
  
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
    search_url = "https://www.tcgplayer.com/search/magic/product?q=#{URI.encode_www_form_component(card_name)}&Language=English&view=grid&productLineName=magic&setName=product"
    
    # Navigate to search page with retry logic
    retries = 0
    begin
      response = main_page.goto(search_url, wait_until: 'networkidle0', timeout: 30000)
      unless response&.ok?
        raise "Search failed with status #{response&.status}"
      end
    rescue => e
      if retries < 2
        retries += 1
        puts "Retrying search (attempt #{retries}): #{e.message}"
        sleep(2)
        retry
      else
        raise
      end
    end
    
    # Wait for search results with retry
    search_results = []
    3.times do |i|
      # Wait for all search results to load
      main_page.wait_for_selector('.search-result', timeout: 5000)
      
      # Get all search results
      search_results = main_page.query_selector_all('.search-result')
      break if search_results.any?
      puts "Retry #{i + 1} waiting for search result..."
      sleep(1)
    end
    
    unless search_results.any?
      return { error: "No search results found" }.to_json
    end
    
    # Find the lowest priced result
    lowest_price_result = nil
    lowest_price = Float::INFINITY
    
    search_results.each do |result|
      begin
        # Get the price element
        price_element = result.query_selector('.search-result__price')
        next unless price_element
        
        # Extract price text and convert to float
        price_text = price_element.evaluate('el => el.textContent.trim()')
        if price_text =~ /\$([\d,.]+)/
          price = $1.gsub(',', '').to_f
          
          # Update lowest price if this one is lower
          if price < lowest_price
            lowest_price = price
            lowest_price_result = result
          end
        end
      rescue => e
        puts "Error processing search result: #{e.message}"
        next
      end
    end
    
    unless lowest_price_result
      return { error: "Could not find valid prices in search results" }.to_json
    end
    
    # Get the product URL from the lowest priced result
    product_url = lowest_price_result.evaluate('el => el.querySelector("a[href*=\'/product/\']").href')
    puts "Selected product with lowest price: $#{lowest_price}"
    
    # Process conditions sequentially instead of in parallel
    conditions = ['Lightly Played', 'Near Mint']
    prices = {}
    
    conditions.each do |condition|
      # Create a new page for each condition
      condition_page = context.new_page
      pages << condition_page
      
      condition_page.default_navigation_timeout = 30000
      
      begin
        result = process_condition(condition_page, product_url, condition)
        prices[condition] = result if result
      ensure
        # Don't close the page yet, we'll close all pages at the end
      end
    end
    
    if prices.empty?
      return { error: 'No valid prices found' }.to_json
    end
    
    { prices: prices }.to_json
    
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
    
    # Clean up context
    begin
      context.close if context
    rescue => e
      puts "Error closing browser context: #{e.message}"
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