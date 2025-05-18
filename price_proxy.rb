require 'sinatra'
require 'httparty'
require 'nokogiri'
require 'json'
require 'puppeteer-ruby'
require 'concurrent'  # For parallel processing
require 'tmpdir'
require 'fileutils'

set :port, 4567
set :public_folder, 'commander_cards'

# Global browser instance
$browser = nil
$browser_mutex = Mutex.new
$browser_retry_count = 0
MAX_RETRIES = 3

# Enable CORS
before do
  response.headers["Access-Control-Allow-Origin"] = "*"
  response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  response.headers["Access-Control-Allow-Headers"] = "Content-Type"
end

def launch_browser
  puts "Launching new browser instance..."
  
  # First, try to kill any existing Chrome processes on port 9222
  begin
    system("lsof -ti:9222 | xargs kill -9 2>/dev/null")
    sleep(1)  # Wait for port to be freed
  rescue => e
    puts "Warning: Could not clean up port 9222: #{e.message}"
  end
  
  # Create a temporary directory for Chrome profile
  chrome_profile_dir = File.join(Dir.tmpdir, "chrome-automation-#{Process.pid}")
  FileUtils.mkdir_p(chrome_profile_dir) unless Dir.exist?(chrome_profile_dir)
  
  # Launch Chrome manually first to ensure it's running
  chrome_path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  unless File.exist?(chrome_path)
    raise "Chrome not found at #{chrome_path}. Please install Google Chrome."
  end
  
  # Build Chrome launch command with explicit path and arguments
  chrome_args = [
    "--remote-debugging-port=9222",
    "--remote-debugging-address=127.0.0.1",
    "--user-data-dir=#{chrome_profile_dir}",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-gpu",
    "--disable-software-rasterizer",
    "--disable-dev-shm-usage",
    "--disable-extensions",
    "--disable-background-networking",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-breakpad",
    "--disable-component-extensions-with-background-pages",
    "--disable-features=TranslateUI,BlinkGenPropertyTrees",
    "--disable-ipc-flooding-protection",
    "--disable-renderer-backgrounding",
    "--enable-features=NetworkService,NetworkServiceInProcess",
    "--force-color-profile=srgb",
    "--metrics-recording-only",
    "--mute-audio",
    "--no-sandbox",
    "--window-size=1920,1080",
    "--bwsi",  # Browser without sign-in
    "--no-default-browser-check",
    "--no-first-run",
    "--no-service-autorun",
    "--password-store=basic",
    "--use-mock-keychain"
  ]
  
  # Use system with array form to properly handle spaces in path
  puts "Launching Chrome with profile directory: #{chrome_profile_dir}"
  pid = Process.spawn(chrome_path, *chrome_args, [:out, :err] => "/dev/null")
  Process.detach(pid)
  
  # Wait for Chrome to start and port to be available
  max_wait = 10
  wait_time = 0
  while wait_time < max_wait
    begin
      TCPSocket.new('127.0.0.1', 9222).close
      puts "Chrome is running and port 9222 is available"
      break
    rescue Errno::ECONNREFUSED
      wait_time += 1
      if wait_time >= max_wait
        # Clean up profile directory on failure
        FileUtils.rm_rf(chrome_profile_dir)
        raise "Chrome failed to start - port 9222 not available after #{max_wait} seconds"
      end
      puts "Waiting for Chrome to start... (#{wait_time}/#{max_wait})"
      sleep(1)
    end
  end
  
  # Try to connect to Chrome with retries
  retries = 0
  max_retries = 3
  browser = nil
  
  while retries < max_retries
    begin
      browser = Puppeteer.connect(browser_url: 'http://127.0.0.1:9222')
      puts "Browser connected successfully"
      break
    rescue => e
      retries += 1
      if retries < max_retries
        puts "Connection attempt #{retries} failed: #{e.message}"
        sleep(1)
      else
        # Clean up profile directory on failure
        FileUtils.rm_rf(chrome_profile_dir)
        puts "Failed to connect after #{max_retries} attempts"
        raise
      end
    end
  end
  
  # Store the profile directory for cleanup
  browser.instance_variable_set(:@profile_dir, chrome_profile_dir)
  
  browser
rescue => e
  # Clean up profile directory on any error
  FileUtils.rm_rf(chrome_profile_dir) if defined?(chrome_profile_dir)
  puts "Error connecting to browser: #{e.message}"
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
    context = browser.create_incognito_browser_context
    
    # Create main page for search
    main_page = context.new_page
    pages << main_page
    
    # Set user agent and viewport
    main_page.user_agent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
    main_page.client.send_message('Emulation.setDeviceMetricsOverride', {
      width: 1920,
      height: 1080,
      deviceScaleFactor: 1,
      mobile: false
    })
    
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
    first_result = nil
    3.times do |i|
      first_result = main_page.query_selector('a[href*="/product/"]')
      break if first_result
      puts "Retry #{i + 1} waiting for search result..."
      sleep(1)
    end
    
    unless first_result
      return { error: "No search results found" }.to_json
    end
    
    # Get the product URL
    product_url = first_result.evaluate('el => el.href')
    
    # Process conditions sequentially instead of in parallel
    conditions = ['Lightly Played', 'Near Mint']
    prices = {}
    
    conditions.each do |condition|
      # Create a new page for each condition
      condition_page = context.new_page
      pages << condition_page
      
      # Set viewport for condition page
      condition_page.client.send_message('Emulation.setDeviceMetricsOverride', {
        width: 1920,
        height: 1080,
        deviceScaleFactor: 1,
        mobile: false
      })
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
  if $browser
    begin
      puts "Closing browser..."
      # Clean up the Chrome profile directory
      if profile_dir = $browser.instance_variable_get(:@profile_dir)
        FileUtils.rm_rf(profile_dir)
      end
      $browser.disconnect if $browser.respond_to?(:disconnect)
      # Kill any remaining Chrome processes
      system("lsof -ti:9222 | xargs kill -9 2>/dev/null")
    rescue => e
      puts "Error closing browser: #{e.message}"
    end
  end
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