require 'sinatra'
require 'httparty'
require 'nokogiri'
require 'json'
require 'puppeteer-ruby'

set :port, 4567
set :public_folder, 'commander_cards'

# Enable CORS
before do
  response.headers["Access-Control-Allow-Origin"] = "*"
  response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  response.headers["Access-Control-Allow-Headers"] = "Content-Type"
end

def launch_browser
  puts "Launching browser..."
  browser = Puppeteer.launch(
    headless: true,
    executable_path: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-accelerated-2d-canvas',
      '--disable-gpu',
      '--window-size=1920x1080',
      '--disable-web-security',
      '--disable-features=IsolateOrigins,site-per-process',
      '--disable-logging',
      '--log-level=3',
      '--silent',
      '--disable-background-networking',
      '--disable-background-timer-throttling',
      '--disable-backgrounding-occluded-windows',
      '--disable-breakpad',
      '--disable-component-extensions-with-background-pages',
      '--disable-extensions',
      '--disable-features=TranslateUI,BlinkGenPropertyTrees',
      '--disable-ipc-flooding-protection',
      '--disable-renderer-backgrounding',
      '--enable-features=NetworkService,NetworkServiceInProcess',
      '--force-color-profile=srgb',
      '--metrics-recording-only',
      '--mute-audio',
      '--disable-notifications',
      '--disable-popup-blocking',
      '--disable-save-password-bubble',
      '--disable-translate',
      '--disable-web-security',
      '--ignore-certificate-errors',
      '--no-first-run',
      '--no-default-browser-check',
      '--no-experiments',
      '--no-pings',
      '--no-sandbox',
      '--no-service-autorun',
      '--no-zygote',
      '--password-store=basic',
      '--use-mock-keychain',
      '--disable-blink-features=AutomationControlled'
    ],
    ignore_default_args: ['--enable-automation'],
    dumpio: true  # Enable logging of browser process stdout/stderr
  )
  puts "Browser launched"
  browser
end

def wait_for_page_load(page, condition)
  puts "Waiting for page to be fully loaded for #{condition}..."
  
  # Wait for network to be idle by waiting for a key element
  begin
    # Wait for either the product container or a loading indicator to disappear
    page.wait_for_selector('.product-details, [data-testid="product-details"], .loading-indicator', timeout: 10000)
    puts "Network is idle (key elements loaded)"
  rescue => e
    puts "Warning: Network idle wait failed: #{e.message}"
  end
  
  # Wait for DOM to be ready by waiting for body
  begin
    page.wait_for_selector('body', timeout: 10000)
    puts "DOM content loaded"
  rescue => e
    puts "Warning: DOM content load wait failed: #{e.message}"
  end
  
  # Wait for specific elements
  begin
    # Wait for the main product container
    page.wait_for_selector('.product-details, [data-testid="product-details"]', timeout: 10000)
    puts "Found product container"
    
    # Wait for any price-related elements to be present
    page.wait_for_selector('.price, [data-testid*="price"], .product-price, .listing-price, .direct-price, .market-price, .product-listing__price-point__amount, .product-listing__price-point__price', timeout: 10000)
    puts "Found price elements"
    
    # Wait for the listings to be loaded
    page.wait_for_selector('.product-listing, [data-testid*="product-listing"], .product-details__listings', timeout: 10000)
    puts "Found listings"
    
    # Additional wait for dynamic content
    sleep(2)
    
    # Verify we have content
    page_content = page.content
    if page_content.include?('product-details') || page_content.include?('data-testid="product-details"')
      puts "Found product details in page content"
      
      # Log the actual HTML structure
      puts "Page structure:"
      container = page.query_selector('.product-details, [data-testid="product-details"]')
      if container
        puts "Container found:", container.evaluate('el => el.outerHTML')
        listings = container.query_selector_all('.product-listing, [data-testid*="product-listing"]')
        puts "Found", listings.length, "listings"
        listings.each do |listing, i|
          puts "Listing", i + 1, ":", listing.evaluate('el => el.outerHTML')
        end
      end
      
      return true
    else
      puts "Warning: Product details not found in page content"
      puts "Page content preview (first 1000 chars):"
      puts page_content[0..1000]
      return false
    end
    
  rescue => e
    puts "Warning: Page load wait failed: #{e.message}"
    puts e.backtrace.join("\n")
    return false
  end
end

get '/prices' do
  content_type :json
  
  card_name = params['card']
  return { error: 'No card name provided' }.to_json unless card_name
  
  browser = nil
  context = nil
  page = nil
  
  begin
    puts "Looking up prices for: #{card_name}"
    
    # Convert card name to TCGPlayer format
    tcg_name = card_name.downcase
      .gsub(/[^a-z0-9\s-]/, '')  # Remove special characters
      .gsub(/\s+/, '-')         # Replace spaces with hyphens
      .gsub(/-+/, '-')          # Replace multiple hyphens with single hyphen
      .gsub(/^-|-$/, '')        # Remove leading/trailing hyphens
    
    puts "Converted card name to TCGPlayer format: #{tcg_name}"
    
    # Initialize browser once for all conditions
    puts "Launching browser..."
    browser = launch_browser
    context = browser.create_incognito_browser_context
    page = context.new_page
    
    # Set user agent
    page.set_user_agent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36')
    
    # Initialize prices hash
    prices = {}
    
    # Search for each condition
    ['lightly played', 'near mint'].each do |condition|
      puts "Searching for #{condition} condition..."
      condition_param = URI.encode_www_form_component(condition)
      search_url = "https://www.tcgplayer.com/search/magic/product?q=#{URI.encode_www_form_component(card_name)}&Condition=#{condition_param}&Language=English"
      
      puts "Using search URL: #{search_url}"
      
      # Navigate to search page
      response = page.goto(search_url, wait_until: 'networkidle0', timeout: 30000)
      unless response&.ok?
        puts "Search page returned status #{response&.status} for #{condition}"
        next
      end
      
      # Add a small delay to ensure browser is ready
      sleep(3)
      
      # Get the first listing directly
      first_listing = page.query_selector('.listing-item__listing-data__info')
      unless first_listing
        puts "No listing found for #{condition}"
        next
      end
      
      # Get the price
      price_element = first_listing.query_selector('.listing-item__listing-data__info__price')
      price_text = price_element ? price_element.evaluate('el => el.textContent.trim()') : nil
      puts "Found price: #{price_text}"
      
      # Get the shipping (look for the div containing 'Shipping')
      shipping = nil
      shipping_divs = first_listing.query_selector_all('div')
      shipping_divs.each do |div|
        text = div.evaluate('el => el.textContent.trim()')
        if text.downcase.include?("shipping")
          shipping = text
          break
        end
      end
      puts "Found shipping: #{shipping}"
      
      # Extract shipping cost
      shipping_cost = if shipping && shipping =~ /\+ \$([\d.]+)/
        $1.to_f
      else
        0.0
      end
      
      # Extract price
      price_value = if price_text && price_text =~ /\$([\d,.]+)/
        # Remove commas and convert to float
        $1.gsub(',', '').to_f
      else
        puts "Could not extract price value from: #{price_text}"
        next
      end
      
      total = price_value + shipping_cost
      
      # Check for foil
      is_foil = first_listing.evaluate('el => {
        return el.querySelector(".foil") || 
               el.querySelector("[data-testid*=\'foil\']") ||
               el.textContent.toLowerCase().includes("foil");
      }')
      
      # Add foil suffix if needed
      condition_key = is_foil ? "#{condition} foil" : condition
      
      puts "Normalized condition: #{condition_key} (Total: $#{total})"
      
      # Store the price
      prices[condition_key] = {
        'price' => price_text,
        'shipping' => shipping,
        'total' => sprintf('$%.2f', total),
        'url' => search_url
      }
      puts "Added price for #{condition_key}: #{prices[condition_key]}"
    end
    
    if prices.empty?
      puts "No valid prices found after processing all conditions"
      return { error: 'No valid prices found' }.to_json
    end
    
    # Transform prices for output, keeping only necessary fields
    prices = prices.transform_values do |v|
      {
        'price' => v['price'],
        'shipping' => v['shipping'],
        'total' => v['total'],
        'url' => v['url']
      }
    end
    
    puts "Successfully found prices: #{prices.keys.join(', ')}"
    puts "Returning prices: #{prices.to_json}"
    { prices: prices }.to_json
    
  rescue => e
    puts "Error in /prices endpoint: #{e.message}"
    puts e.backtrace.join("\n")
    { error: e.message }.to_json
  ensure
    # Clean up resources only after all conditions are processed
    if page
      begin
        puts "Closing page..."
        page.close
      rescue => e
        puts "Error closing page: #{e.message}"
      end
    end
    
    if context
      begin
        puts "Closing browser context..."
        context.close
      rescue => e
        puts "Error closing context: #{e.message}"
      end
    end
    
    if browser
      begin
        puts "Closing browser..."
        browser.close
      rescue => e
        puts "Error closing browser: #{e.message}"
      end
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