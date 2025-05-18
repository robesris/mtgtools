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
          condition_page.default_navigation_timeout = 15000  # 15 seconds
          condition_page.default_timeout = 10000  # 10 seconds
          
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
end

# Process a single condition
def process_condition(page, product_url, condition, request_id, card_name)
  begin
    # Navigate to the product page with condition filter
    condition_param = URI.encode_www_form_component(condition)
    filtered_url = "#{product_url}#{product_url.include?('?') ? '&' : '?'}Condition=#{condition_param}&Language=English"
    $logger.info("Request #{request_id}: Navigating to filtered URL: #{filtered_url}")
    
    begin
      # Wait for network to be idle and for the page to be fully loaded
      response = page.goto(filtered_url, wait_until: 'networkidle0')
      $logger.info("Request #{request_id}: Product page response status: #{response.status}")
      
      # Wait specifically for listing items
      begin
        page.wait_for_selector('.listing-item', timeout: 10000)
        $logger.info("Request #{request_id}: Listing items found")
        
        # Get all listings and their prices
        price_data = page.evaluate(<<~'JS')
          function() {
            function extractNumericPrice(text) {
              if (!text) return null;
              // Try to match price patterns like $1.23, $1,234.56, etc.
              const match = text.match(/\$[\d,]+(\.\d{2})?/);
              if (!match) return null;
              return parseFloat(match[0].replace(/[$,]/g, ''));
            }

            // Get all listing items
            const listings = Array.from(document.querySelectorAll('.listing-item'));
            if (!listings.length) {
              console.log('No listings found');
              return null;
            }

            console.log('Found', listings.length, 'listings');

            // Process each listing
            const validListings = listings.map(listing => {
              // Get price and shipping elements using exact class names
              const priceElement = listing.querySelector('.listing-item__listing-data__info__price');
              const shippingElement = listing.querySelector('.shipping-messages__price');
              
              if (!priceElement) {
                console.log('No price element found in listing');
                return null;
              }

              const basePrice = extractNumericPrice(priceElement.textContent);
              if (basePrice === null) {
                console.log('Could not extract base price from:', priceElement.textContent);
                return null;
              }

              // Get shipping price if available
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
              console.log('Valid listing found:', { basePrice, shippingPrice, totalPrice });
              
              return {
                basePrice,
                shippingPrice,
                totalPrice,
                priceElement: priceElement.textContent.trim(),
                shippingElement: shippingElement ? shippingElement.textContent.trim() : 'no shipping info'
              };
            }).filter(listing => listing !== null)
              .sort((a, b) => a.totalPrice - b.totalPrice);

            if (!validListings.length) {
              console.log('No valid listings found after processing');
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
                  price: lowestListing.priceElement,
                  shipping: lowestListing.shippingElement
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
        $logger.error("Request #{request_id}: Timeout waiting for listing items: #{e.message}")
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

puts "Price proxy server starting on http://localhost:4567"
puts "Note: You need to install Chrome/Chromium for Puppeteer to work" 