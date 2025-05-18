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
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
end
$logger.info("=== Starting new price proxy server session ===")
$logger.info("Log file cleared and initialized")

# Global browser instance
$browser = nil
$browser_mutex = Mutex.new
$browser_retry_count = 0
MAX_RETRIES = 3

# Add request tracking with concurrent handling
$active_requests = Concurrent::Hash.new
$request_mutex = Mutex.new

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

    # Get or initialize browser
    browser = get_browser
    context = nil
    
    begin
      # Create a new incognito context for this request
      context = browser.create_incognito_browser_context
      $logger.info("Created new browser context for request #{request_id}")
      
      # Create a new page for the search
      search_page = context.new_page
      search_page.default_navigation_timeout = 15000  # 15 seconds for navigation
      search_page.default_timeout = 10000  # 10 seconds for other operations
      
      # Navigate to TCGPlayer search
      $logger.info("Request #{request_id}: Navigating to TCGPlayer search for: #{card_name}")
      search_url = "https://www.tcgplayer.com/search/magic/product?q=#{CGI.escape(card_name)}&view=grid"
      $logger.info("Request #{request_id}: Search URL: #{search_url}")
      
      begin
        response = search_page.goto(search_url, wait_until: 'networkidle0')
        $logger.info("Request #{request_id}: Search page response status: #{response.status}")
      rescue Puppeteer::TimeoutError => e
        $logger.error("Request #{request_id}: Timeout navigating to search page: #{e.message}")
        return { error: 'Timeout searching for card', legality: legality }.to_json
      rescue => e
        $logger.error("Request #{request_id}: Error navigating to search page: #{e.message}")
        $logger.error(e.backtrace.join("\n"))
        return { error: "Error searching for card: #{e.message}", legality: legality }.to_json
      end
      
      # Log the page content for debugging
      $logger.info("Request #{request_id}: Page title: #{search_page.title}")
      $logger.info("Request #{request_id}: Current URL: #{search_page.url}")
      
      # Get the first product URL with multiple possible selectors
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
          $logger.info("Request #{request_id}: Trying selector: #{selector}")
          search_page.wait_for_selector(selector, timeout: 5000)  # 5 seconds for selector wait
          found_selector = selector
          $logger.info("Request #{request_id}: Found working selector: #{selector}")
          break
        rescue => e
          $logger.info("Request #{request_id}: Selector #{selector} not found: #{e.message}")
        end
      end
      
      unless found_selector
        $logger.error("Request #{request_id}: Could not find any product grid selectors")
        # Take a screenshot for debugging
        screenshot_path = "search_error_#{Time.now.to_i}.png"
        search_page.screenshot(path: screenshot_path)
        $logger.info("Request #{request_id}: Saved error screenshot to #{screenshot_path}")
        return { error: 'Could not find product listings', legality: legality }.to_json
      end
      
      # Find the lowest-priced valid product on the search page
      lowest_product = search_page.evaluate(<<~JAVASCRIPT, cardName: card_name)
        function(cardName) {
          function extractNumericPrice(text) {
            if (!text) return null;
            // Try to match price patterns like $1.23, $1,234.56, etc.
            const match = text.match(/\$[\d,]+(\.\d{2})?/);
            if (!match) return null;
            return parseFloat(match[0].replace(/[$,]/g, ''));
          }

          function isExactCardMatch(title) {
            // Convert both to lowercase for case-insensitive comparison
            const searchTitle = title.toLowerCase();
            const searchName = cardName.toLowerCase();
            
            // Check for art cards and proxies
            if (searchTitle.includes('art card') || searchTitle.includes('proxy')) {
              return false;
            }
            
            // Log the title we're checking
            console.log('Checking title:', searchTitle, 'against card name:', searchName);
            
            // Find the card name in the title
            const nameIndex = searchTitle.indexOf(searchName);
            if (nameIndex === -1) {
              console.log('Card name not found in title');
              return false;
            }
            
            // Check if there are any characters before the card name
            if (nameIndex > 0) {
              const beforeName = searchTitle.slice(0, nameIndex).trim();
              // Allow words like "promo", "judge", "promos" before the card name
              const allowedPrefixes = ['promo', 'judge', 'promos', 'commander', 'collectors'];
              const hasAllowedPrefix = allowedPrefixes.some(prefix => beforeName.endsWith(prefix));
              if (beforeName && !hasAllowedPrefix && !/[\-\(\)\[\]\{\}\.,;:]$/.test(beforeName)) {
                console.log('Invalid characters before card name:', beforeName);
                return false;
              }
            }
            
            // Check if there are any characters after the card name
            const afterIndex = nameIndex + searchName.length;
            if (afterIndex < searchTitle.length) {
              const afterName = searchTitle.slice(afterIndex).trim();
              // Allow words like "promo", "judge", "promos" after the card name
              const allowedSuffixes = ['promo', 'judge', 'promos', 'commander', 'collectors'];
              const hasAllowedSuffix = allowedSuffixes.some(suffix => afterName.startsWith(suffix));
              if (afterName && !hasAllowedSuffix && !/^[\-\(\)\[\]\{\}\.,;:]/.test(afterName)) {
                console.log('Invalid characters after card name:', afterName);
                return false;
              }
            }
            
            console.log('Title is a match');
            return true;
          }

          // Get all product cards
          const productCards = Array.from(document.querySelectorAll('.search-result'));
          console.log('Found', productCards.length, 'product cards');
          
          // Log the HTML structure of the first card to see what we're working with
          if (productCards.length > 0) {
            console.log('First card HTML:', productCards[0].outerHTML);
            console.log('Available classes in first card:', 
              Array.from(productCards[0].classList).join(', '));
          }

          // Filter and sort product cards
          const validProducts = productCards
            .map((card, index) => {
              console.log(`\nProcessing card ${index + 1}:`);
              
              // Log all elements with class names containing 'product' or 'price'
              const allElements = card.querySelectorAll('*');
              const relevantElements = Array.from(allElements).filter(el => {
                const classes = Array.from(el.classList).join(' ').toLowerCase();
                return classes.includes('product') || classes.includes('price');
              });
              
              console.log('Found relevant elements:', 
                relevantElements.map(el => ({
                  tag: el.tagName,
                  classes: Array.from(el.classList).join(' '),
                  text: el.textContent.trim().slice(0, 50) // First 50 chars of text
                }))
              );

              // Try to find title and price elements
              const titleElement = card.querySelector('[class*="product"][class*="name"], [class*="product"][class*="title"]');
              const priceElement = card.querySelector('[class*="price"]');
              const linkElement = card.querySelector('a[href*="/product/"]');
              
              console.log('Found elements:', {
                title: titleElement ? {
                  class: Array.from(titleElement.classList).join(' '),
                  text: titleElement.textContent.trim()
                } : null,
                price: priceElement ? {
                  class: Array.from(priceElement.classList).join(' '),
                  text: priceElement.textContent.trim()
                } : null,
                link: linkElement ? {
                  href: linkElement.href,
                  text: linkElement.textContent.trim()
                } : null
              });
              
              if (!titleElement || !priceElement || !linkElement) {
                console.log('Missing required elements:', {
                  hasTitle: !!titleElement,
                  hasPrice: !!priceElement,
                  hasLink: !!linkElement
                });
                return null;
              }
              
              const title = titleElement.textContent.trim();
              const priceText = priceElement.textContent.trim();
              console.log('Checking product:', { title, priceText });
              
              if (!isExactCardMatch(title)) {
                console.log('Title does not match card name');
                return null;
              }
              
              const price = extractNumericPrice(priceText);
              if (price === null) {
                console.log('Could not extract price from:', priceText);
                return null;
              }
              
              // Get the clean URL
              const url = new URL(linkElement.href);
              const cleanUrl = url.origin + url.pathname;
              
              console.log('Valid product found:', { title, price, url: cleanUrl });
              return {
                title,
                price,
                url: cleanUrl
              };
            })
            .filter(product => product !== null)
            .sort((a, b) => a.price - b.price);

          if (!validProducts.length) {
            console.log('No valid products found after filtering');
            return null;
          }

          // Get the lowest priced valid product
          const lowestProduct = validProducts[0];
          console.log('Selected lowest product:', lowestProduct.title, 'at', lowestProduct.price);
          
          return {
            url: lowestProduct.url,
            title: lowestProduct.title,
            price: lowestProduct.price
          };
        }
      JAVASCRIPT
      
      if !lowest_product
        $logger.error("Request #{request_id}: No valid products found for: #{card_name}")
        return { error: 'No valid product found', legality: legality }.to_json
      end
      
      $logger.info("Request #{request_id}: Found lowest priced product: #{lowest_product['title']} at $#{lowest_product['price']}")
      
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
        condition_page.default_navigation_timeout = 15000  # 15 seconds
        condition_page.default_timeout = 10000  # 10 seconds
        
        begin
          $logger.info("Request #{request_id}: Processing condition: #{condition}")
          result = process_condition(condition_page, lowest_product['url'], condition, request_id, card_name)
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
      # Clean up the context
      if context
        begin
          context.close
          $logger.info("Request #{request_id}: Closed browser context")
        rescue => e
          $logger.error("Request #{request_id}: Error closing browser context: #{e.message}")
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
  end
end

# Process a single condition
def process_condition(page, product_url, condition, request_id, card_name)
  begin
    # Navigate to the product page with condition filter
    condition_param = URI.encode_www_form_component(condition)
    filtered_url = "#{product_url}?Condition=#{condition_param}&Language=English"
    $logger.info("Request #{request_id}: Navigating to filtered URL: #{filtered_url}")
    
    begin
      # Wait for network to be idle and for the page to be fully loaded
      response = page.goto(filtered_url, wait_until: 'networkidle0')
      $logger.info("Request #{request_id}: Product page response status: #{response.status}")
      
      # Wait for the regular listing price element to appear
      begin
        page.wait_for_selector('.listing-item', timeout: 10000)
        $logger.info("Request #{request_id}: Listing items found")
      rescue => e
        $logger.error("Request #{request_id}: Timeout waiting for listing items: #{e.message}")
        # Take a screenshot for debugging
        screenshot_path = "price_error_#{condition}_#{Time.now.to_i}.png"
        page.screenshot(path: screenshot_path)
        $logger.info("Request #{request_id}: Saved error screenshot to #{screenshot_path}")
        return nil
      end
      
      # Give extra time for dynamic content to stabilize
      sleep(2)
      
      # Try to get price with simplified extraction
      price_data = page.evaluate(<<~'JS', cardName: card_name)
        function(cardName) {
          function extractNumericPrice(text) {
            if (!text) return null;
            // Try to match price patterns like $1.23, $1,234.56, etc.
            const match = text.match(/\$[\d,]+(\.\d{2})?/);
            if (!match) return null;
            return parseFloat(match[0].replace(/[$,]/g, ''));
          }

          function isExactCardMatch(title) {
            // Convert both to lowercase for case-insensitive comparison
            const searchTitle = title.toLowerCase();
            const searchName = cardName.toLowerCase();
            
            // Check for art cards and proxies
            if (searchTitle.includes('art card') || searchTitle.includes('proxy')) {
              return false;
            }
            
            // Log the title we're checking
            console.log('Checking title:', searchTitle, 'against card name:', searchName);
            
            // Find the card name in the title
            const nameIndex = searchTitle.indexOf(searchName);
            if (nameIndex === -1) {
              console.log('Card name not found in title');
              return false;
            }
            
            // Check if there are any characters before the card name
            if (nameIndex > 0) {
              const beforeName = searchTitle.slice(0, nameIndex).trim();
              // Allow words like "promo", "judge", "promos" before the card name
              const allowedPrefixes = ['promo', 'judge', 'promos', 'commander', 'collectors'];
              const hasAllowedPrefix = allowedPrefixes.some(prefix => beforeName.endsWith(prefix));
              if (beforeName && !hasAllowedPrefix && !/[\-\(\)\[\]\{\}\.,;:]$/.test(beforeName)) {
                console.log('Invalid characters before card name:', beforeName);
                return false;
              }
            }
            
            // Check if there are any characters after the card name
            const afterIndex = nameIndex + searchName.length;
            if (afterIndex < searchTitle.length) {
              const afterName = searchTitle.slice(afterIndex).trim();
              // Allow words like "promo", "judge", "promos" after the card name
              const allowedSuffixes = ['promo', 'judge', 'promos', 'commander', 'collectors'];
              const hasAllowedSuffix = allowedSuffixes.some(suffix => afterName.startsWith(suffix));
              if (afterName && !hasAllowedSuffix && !/^[\-\(\)\[\]\{\}\.,;:]/.test(afterName)) {
                console.log('Invalid characters after card name:', afterName);
                return false;
              }
            }
            
            console.log('Title is a match');
            return true;
          }

          // Get all listing items
          const listings = Array.from(document.querySelectorAll('.listing-item'));
          if (!listings.length) {
            console.log('No listings found');
            return null;
          }

          console.log('Found', listings.length, 'listings');

          // Filter and sort listings
          const validListings = listings
            .map(listing => {
              // Get the title specifically from the product-card__title element
              const titleElement = listing.querySelector('.product-card__title') || 
                                 listing.querySelector('.listing-item__title');
              const priceElement = listing.querySelector('.listing-item__listing-data__info__price');
              const shippingElement = listing.querySelector('.shipping-messages__price');
              
              if (!titleElement || !priceElement) {
                console.log('Missing title or price element');
                return null;
              }
              
              const title = titleElement.textContent.trim();
              console.log('Checking listing title:', title);
              
              if (!isExactCardMatch(title)) {
                console.log('Title does not match card name');
                return null;
              }
              
              const basePrice = extractNumericPrice(priceElement.textContent);
              if (basePrice === null) {
                console.log('Could not extract price from:', priceElement.textContent);
                return null;
              }
              
              // Get shipping info from the same listing
              let shippingPrice = 0;
              if (shippingElement) {
                const shippingText = shippingElement.textContent.trim();
                if (shippingText.toLowerCase().includes('free shipping')) {
                  shippingPrice = 0;
                } else {
                  const price = extractNumericPrice(shippingText);
                  if (price !== null) {
                    shippingPrice = price;
                  }
                }
              }
              
              const totalPrice = basePrice + shippingPrice;
              console.log('Valid listing found:', { title, basePrice, shippingPrice, totalPrice });
              return {
                listing,
                title,
                basePrice,
                shippingPrice,
                totalPrice,
                priceElement,
                shippingElement
              };
            })
            .filter(listing => listing !== null)
            .sort((a, b) => a.totalPrice - b.totalPrice);

          if (!validListings.length) {
            console.log('No valid listings found after filtering');
            return null;
          }

          // Get the lowest priced valid listing
          const lowestListing = validListings[0];
          console.log('Selected lowest listing:', lowestListing.title, 'at', lowestListing.totalPrice);
          
          return {
            price: `$${lowestListing.totalPrice.toFixed(2)}`,
            url: window.location.href,
            debug: {
              basePrice: lowestListing.basePrice,
              shippingPrice: lowestListing.shippingPrice,
              totalPrice: lowestListing.totalPrice,
              title: lowestListing.title,
              source: 'lowest_valid_listing',
              rawText: {
                price: lowestListing.priceElement.textContent.trim(),
                shipping: lowestListing.shippingElement ? lowestListing.shippingElement.textContent.trim() : 'no shipping info'
              }
            }
          };
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

puts "Price proxy server starting on http://localhost:4567"
puts "Note: You need to install Chrome/Chromium for Puppeteer to work" 