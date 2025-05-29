require_relative 'logging'
require_relative 'browser_manager'
require_relative 'rate_limiter'
require_relative 'screenshot_manager'

class CardSearch
  class << self
    def search_card(card_name, request_id)
      begin
        # Clean up old search wait screenshots
        Dir.glob("search_wait_*.png").each do |file|
          begin
            File.delete(file)
          rescue => e
          end
        end
        
        # Create a new page for the search
        search_page = BrowserManager.create_page
        
        # Forward browser console logs (and errors) to the Ruby logger
        search_page.on("console", ->(msg) { $file_logger.info("Request #{ request_id }: (Browser Console) #{ msg.text }") })
        search_page.on("pageerror", ->(err) { $file_logger.error("Request #{ request_id }: (Browser Error) #{ err }") })
        
        # Inject the card search function first
        js_code = File.read('lib/js/card_search.js')
        begin
          $file_logger.info("Request #{request_id}: Injecting card search function")
          
          # Wrap the code in a function that will be immediately executed
          wrapped_js = <<~JS
            (function() {
              #{js_code}
              return typeof window.cardSearch === 'function';
            })();
          JS
          
          # Evaluate the wrapped code
          initialization_result = search_page.evaluate(wrapped_js)
          unless initialization_result
            raise "Failed to initialize card search function - initialization returned false"
          end
          
          # Verify the function exists and is callable
          function_exists = search_page.evaluate(<<~JS)
            (function() {
              try {
                if (typeof window.cardSearch !== 'function') {
                  console.error('cardSearch is not a function');
                  return false;
                }
                // Try a test call to ensure it's properly defined
                const testResult = window.cardSearch({ cardName: 'test' });
                if (!(testResult instanceof Promise)) {
                  console.error('cardSearch did not return a Promise');
                  return false;
                }
                console.log('Successfully verified cardSearch function');
                return true;
              } catch (error) {
                console.error('Error verifying cardSearch function:', error);
                return false;
              }
            })()
          JS
          
          unless function_exists
            raise "Failed to verify card search function - check browser console for details"
          end
          
          $file_logger.info("Request #{request_id}: Successfully injected and verified card search function")
        rescue => e
          $file_logger.error("Request #{request_id}: Error injecting card search function: #{e.message}")
          $file_logger.error(e.backtrace.join("\n"))
          raise
        end
        
        # Expose screenshot function to page
        search_page.expose_function('puppeteerScreenshot', ->(prefix) {
          begin
            filename = "#{prefix}.png"
            search_page.screenshot(path: filename)
            $file_logger.info("Request #{request_id}: Took debug screenshot: #{filename}")
            $file_logger.info("Request #{ request_id }: (Debug) Screenshot function exposed (puppeteerScreenshot)")
          rescue => e
            $file_logger.error("Request #{request_id}: Error taking debug screenshot: #{e.message}")
          end
        })
        
        # Navigate to TCGPlayer search
        $file_logger.info("Request #{request_id}: Navigating to TCGPlayer search for: #{card_name}")
        search_url = "https://www.tcgplayer.com/search/all/product?Condition=#{CGI.escape(condition)}&Language=English&q=#{CGI.escape(card_name)}&view=grid"
        $file_logger.info("Request #{request_id}: Search URL: #{search_url}")
        
        begin
          search_page.goto(search_url, wait_until: 'domcontentloaded', timeout: get_navigation_timeout)
          $file_logger.info("Request #{request_id}: Initial page load complete")
          
          # Wait for search results to load
          wait_time = get_timeout(5)
          $file_logger.info("Request #{request_id}: Waiting #{wait_time} seconds for dynamic content to load...")
          sleep(wait_time)
          
          # Extract product data with improved selectors and validation
          lowest_priced_product = search_page.evaluate(<<~JS, { cardName: card_name, condition: condition }.to_json)
            function(params) {
              const { cardName, condition } = JSON.parse(params);
              console.log('Searching for card:', cardName, 'with condition:', condition);
              
              // Find all search results
              const searchResults = Array.from(document.querySelectorAll('.search-result'));
              console.log('Found search results:', searchResults.length);
              
              // Process each search result
              const validProducts = searchResults.map(result => {
                const titleElement = result.querySelector('.product-card__title');
                const priceElement = result.querySelector('.inventory__price-with-shipping');
                const linkElement = result.querySelector('a[href*="/product"]');
                
                if (!titleElement || !priceElement || !linkElement) {
                  console.log('Missing required elements in search result');
                  return null;
                }
                
                const title = titleElement.textContent.trim();
                const priceText = priceElement.textContent.trim();
                const url = linkElement.href;
                
                // Skip if no title or price
                if (!title || !priceText) {
                  console.log('Empty title or price text');
                  return null;
                }
                
                // Skip art cards and proxies
                if (title.toLowerCase().includes('art card') || 
                    title.toLowerCase().includes('proxy') ||
                    title.toLowerCase().includes('playtest')) {
                  console.log('Skipping non-playable card:', title);
                  return null;
                }
                
                // Extract numeric price ONLY from inventory__price-with-shipping
                const priceMatch = priceText.match(/\$([\d,]+\.\d{2})/);
                const price = priceMatch ? parseFloat(priceMatch[1].replace(/,/g, '')) : null;
                
                // Validate exact card match
                const normalizedTitle = title.toLowerCase().trim().replace(/\s+/g, ' ');
                const normalizedCardName = cardName.toLowerCase().trim().replace(/\s+/g, ' ');
                const isMatch = normalizedTitle === normalizedCardName;
                
                console.log('Product validation:', {
                  title,
                  price,
                  isMatch,
                  hasValidPrice: price !== null && price > 0,
                  url
                });
                
                if (isMatch && price !== null && price > 0) {
                  return { title, price, url };
                }
                return null;
              }).filter(Boolean);
              
              // Find the lowest priced valid product
              if (validProducts.length > 0) {
                const lowestPriceProduct = validProducts.reduce((lowest, current) => 
                  current.price < lowest.price ? current : lowest
                );
                console.log('Found lowest priced product:', lowestPriceProduct);
                return lowestPriceProduct;
              }
              
              console.log('No valid products found');
              return null;
            }
          JS
          
          # Ruby-side filtering and price selection
          products = lowest_priced_product
          matches = products.select { |p| is_exact_card_match(card_name, p['title']) }
          matches = matches.map do |p|
            price = p['price'].gsub(/[^0-9.]/, '').to_f
            p.merge('numeric_price' => price)
          end.select { |p| p['numeric_price'] > 0 }
          lowest = matches.min_by { |p| p['numeric_price'] }

          if !lowest
            $file_logger.error("Request #{request_id}: No valid products found for: #{card_name}")
            return nil
          end

          $file_logger.info("Request #{request_id}: Chosen card - Name: #{lowest['title']}, Price: $#{lowest['numeric_price']}, URL: #{lowest['url']}")
          filename = "after_card_search.png"
          search_page.screenshot(path: filename)
          $file_logger.info("Request #{ request_id }: Took debug screenshot: #{filename}")
          lowest
          
        rescue => e
          $file_logger.error("Request #{request_id}: Timeout waiting for search results: #{e.message}")
          # (Optional) log the page's HTML (for debugging) and take a debug screenshot (if wait_for_selector times out)
          html = search_page.content
          $file_logger.info("Request #{request_id}: (Debug) Page HTML (truncated) (timeout): #{html[0..500]}…")
          filename = "search_results_timeout.png"
          search_page.screenshot(path: filename)
          $file_logger.info("Request #{ request_id }: Took debug screenshot: #{filename}")
          
          # Take a screenshot for debugging
          ScreenshotManager.take_error_screenshot(search_page, card_name, Time.now.to_i, $file_logger, request_id)
          return nil
        end
        
      ensure
        search_page.close
      end
    end

    def process_condition(page, product_url, condition, request_id, card_name)
      begin
        # Add redirect prevention script
        RateLimiter.add_redirect_prevention(page, request_id)

        # Navigate to the product page with condition filter
        condition_param = URI.encode_www_form_component(condition)
        filtered_url = "#{product_url}#{product_url.include?('?') ? '&' : '?'}Condition=#{condition_param}&Language=English"
        $file_logger.info("Request #{request_id}: Navigating to filtered URL: #{filtered_url}")
        
        begin
          # Navigate to the page with redirect prevention
          response = page.goto(filtered_url, 
            wait_until: 'domcontentloaded',
            timeout: ENV['RACK_ENV'] == 'production' ? 120000 : 30000  # 2 minutes in production, 30 seconds locally
          )
          
          # Check for rate limiting after navigation
          if RateLimiter.handle_rate_limit(page, request_id)
            # If we hit rate limiting, try one more time
            sleep(rand(5..10))
            response = page.goto(filtered_url, 
              wait_until: 'domcontentloaded',
              timeout: ENV['RACK_ENV'] == 'production' ? 120000 : 30000  # 2 minutes in production, 30 seconds locally
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
          ScreenshotManager.take_screenshot(page, "loading_sequence_#{condition}", screenshot_count, Time.now.to_i, $file_logger, request_id)
          screenshot_count += 1
          last_screenshot_time = Time.now

          # Log our current selectors for the product page
          $file_logger.info("Request #{request_id}: Current product page selectors:")
          $file_logger.info("  Container: .listing-item")
          $file_logger.info("  Base Price: .listing-item__listing-data__info__price")
          $file_logger.info("  Shipping: .shipping-messages__price")

          # Main loop - continue until we hit max screenshots
          while Time.now - start_time < max_wait_time && screenshot_count < max_screenshots
            current_time = Time.now
            
            # Take a screenshot if enough time has passed
            if current_time - last_screenshot_time >= screenshot_interval
              begin
                ScreenshotManager.take_screenshot(page, "loading_sequence_#{condition}", screenshot_count, Time.now.to_i, $file_logger, request_id)
                screenshot_count += 1
                last_screenshot_time = current_time
                
                # Evaluate the page for listings
                listings_html = page.evaluate(<<~JS)
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
                              url: window.location.href,
                              details: {
                                basePrice: price.toFixed(2),
                                shippingPrice: shippingPrice.toFixed(2),
                                shippingText: shippingText
                              }
                            };
                          }
                        }
                      }

                      return {
                        success: true,
                        listings: listings,
                        priceData: priceData,
                        headerText: listingsHeader ? listingsHeader.textContent.trim() : null
                      };
                    } catch (error) {
                      return {
                        success: false,
                        error: error.message,
                        stack: error.stack
                      };
                    }
                  }
                JS

                # Log detailed info for the third screenshot
                if screenshot_count == 3
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

                    if listings_html['priceData'] && listings_html['priceData']['success']
                      $file_logger.info("  === PRICE DATA ===")
                      $file_logger.info("    Total Price: $#{listings_html['priceData']['price']}")
                      $file_logger.info("    Base Price: $#{listings_html['priceData']['details']['basePrice']}")
                      $file_logger.info("    Shipping: $#{listings_html['priceData']['details']['shippingPrice']}")
                      $file_logger.info("    Shipping Text: #{listings_html['priceData']['details']['shippingText']}")
                    end
                  else
                    $file_logger.error("  Error evaluating listing: #{listings_html['error']}")
                    $file_logger.error("  Stack trace: #{listings_html['stack']}")
                  end
                  $file_logger.info("=== END OF LISTINGS INFO ===")
                end

                # If we found a valid price, return it immediately
                if listings_html.is_a?(Hash) && listings_html['success'] && listings_html['listings'][0]
                  base_price = PriceProcessor.parse_base_price(listings_html['listings'][0]['basePrice']['text'])
                  shipping_price = PriceProcessor.calculate_shipping_price(listings_html['listings'][0])
                  $file_logger.info("Request #{request_id}: Found valid price: $#{base_price}")
                  
                  result = {
                    'success' => true,
                    'price' => "$#{PriceProcessor.total_price_str(base_price, shipping_price)}",
                    'url' => page.url
                  }
                  $file_logger.info("Request #{request_id}: Breaking out of screenshot loop with price: #{result.inspect}")
                  return result
                end
              rescue => e
                $file_logger.error("Request #{request_id}: Error evaluating listings HTML: #{e.message}")
                $file_logger.error(e.backtrace.join("\n"))
              end
            end

            # Small sleep to prevent tight loop
            sleep(0.1)
          end

          nil  # Return nil if no valid price found
        rescue => e
          $file_logger.error("Request #{request_id}: Error processing condition: #{e.message}")
          $file_logger.error(e.backtrace.join("\n"))
          nil
        end
      rescue => e
        $file_logger.error("Request #{request_id}: Error in process_condition: #{e.message}")
        $file_logger.error(e.backtrace.join("\n"))
        nil
      end
    end

    # Helper for exact card name match
    def is_exact_card_match(card_name, product_name)
      card_name.to_s.strip.downcase == product_name.to_s.strip.downcase
    end
  end
end 