require_relative 'logging'
require_relative 'price_processor'

module PriceExtractor
  # JavaScript code for extracting prices from TCGPlayer search results
  SEARCH_RESULTS_JS = <<~'JS'
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

  # JavaScript code for extracting prices from TCGPlayer product listings
  LISTINGS_JS = <<~'JS'
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
              classes: shipping.className,
              html: shipping.outerHTML  // Add the full HTML for debugging
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
              
              // Log the shipping details for debugging
              console.log('Shipping details:', {
                shippingText,
                shippingMatch,
                shippingPrice,
                shippingElement: shipping ? {
                  text: shipping.textContent,
                  html: shipping.outerHTML,
                  classes: shipping.className
                } : null
              });
              
              priceData = {
                success: true,
                found: true,
                price: (price + shippingPrice).toFixed(2),  // Total price
                basePrice: price.toFixed(2),  // Base price only
                shippingPrice: shippingPrice.toFixed(2),  // Shipping price only
                url: window.location.href,  // Use the current URL which is our filtered product page
                details: {
                  basePrice: price.toFixed(2),
                  shippingPrice: shippingPrice.toFixed(2),
                  shippingText: shippingText,
                  shippingElement: shipping ? shipping.outerHTML : null  // Add shipping element HTML for debugging
                }
              };
            }
          }
        }

        // Return both the listings data and price data
        return {
          success: true,
          found: true,
          headerText: listingsHeader ? listingsHeader.textContent : null,
          listings: listings,
          priceData: priceData || {
            success: false,
            found: false,
            message: "No valid price found in first listing"
          }
        };
      } catch (e) {
        console.error('Error processing listing:', e);
        return { 
          success: false,
          found: false, 
          error: e.toString(),
          message: "Error evaluating listing",
          stack: e.stack
        };
      }
    }
  JS

  # JavaScript code for preventing redirects to error pages
  REDIRECT_PREVENTION_JS = <<~'JS'
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

  class << self
    # Extract the lowest priced product from search results
    def extract_lowest_priced_product(page, card_name, request_id)
      begin
        lowest_priced_product = page.evaluate(SEARCH_RESULTS_JS, { cardName: card_name }.to_json)
        
        if !lowest_priced_product
          $file_logger.error("Request #{request_id}: No valid products found for: #{card_name}")
          return nil
        end
        
        $file_logger.info("Request #{request_id}: Found lowest priced product: #{lowest_priced_product['title']} at $#{lowest_priced_product['price']}")
        lowest_priced_product
      rescue => e
        $file_logger.error("Request #{request_id}: Error extracting lowest priced product: #{e.message}")
        nil
      end
    end

    # Extract prices from product listings
    def extract_listing_prices(page, request_id)
      begin
        listings_html = page.evaluate(LISTINGS_JS)
        
        if listings_html.is_a?(Hash) && listings_html['success'] && listings_html['listings'][0]
          base_price = PriceProcessor.parse_base_price(listings_html['listings'][0]['basePrice']['text'])
          shipping_price = PriceProcessor.calculate_shipping_price(listings_html['listings'][0])
          
          # Log detailed price information
          $file_logger.info("Request #{request_id}: Price details:")
          $file_logger.info("  Base price text: #{listings_html['listings'][0]['basePrice']['text']}")
          $file_logger.info("  Base price cents: #{base_price}")
          $file_logger.info("  Shipping text: #{listings_html['listings'][0]['shipping']&.dig('text')}")
          $file_logger.info("  Shipping cents: #{shipping_price}")
          $file_logger.info("  Total price: #{PriceProcessor.total_price_str(base_price, shipping_price)}")
          
          {
            'success' => true,
            'price' => PriceProcessor.total_price_str(base_price, shipping_price),
            'base_price' => PriceProcessor.total_price_str(base_price, 0),
            'shipping' => PriceProcessor.total_price_str(0, shipping_price),
            'url' => page.url  # Use the current page URL which is our filtered product page
          }
        else
          {
            'success' => false,
            'message' => listings_html['message'] || 'No valid listings found'
          }
        end
      rescue => e
        $file_logger.error("Request #{request_id}: Error extracting listing prices: #{e.message}")
        {
          'success' => false,
          'message' => e.message
        }
      end
    end

    # Add redirect prevention to a page
    def add_redirect_prevention(page, request_id)
      begin
        page.evaluate(REDIRECT_PREVENTION_JS)
        $file_logger.info("Request #{request_id}: Added redirect prevention")
        true
      rescue => e
        $file_logger.error("Request #{request_id}: Error adding redirect prevention: #{e.message}")
        false
      end
    end
  end
end 