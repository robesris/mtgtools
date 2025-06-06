require_relative 'logging'
require_relative 'price_processor'

module PriceExtractor
  # JavaScript code for extracting prices from TCGPlayer search results
  SEARCH_RESULTS_JS = <<~'JS'
    function(params) {
      const cardName = JSON.parse(params).cardName;
      console.log('Searching for card:', cardName);
      
      // Add initial page content logging
      console.log('Initial page state:', {
        url: window.location.href,
        title: document.title,
        hasSearchResults: !!document.querySelector('.search-results'),
        hasProductCards: !!document.querySelector('.product-card__product'),
        bodyContent: document.body.textContent.slice(0, 500) + '...', // First 500 chars of body content
        searchForm: document.querySelector('form[action*="search"]') ? {
          action: document.querySelector('form[action*="search"]').action,
          method: document.querySelector('form[action*="search"]').method,
          html: document.querySelector('form[action*="search"]').outerHTML
        } : 'No search form found'
      });

      // Log any error messages that might be present
      const errorMessages = Array.from(document.querySelectorAll('.error-message, .alert, .message')).map(el => ({
        text: el.textContent.trim(),
        className: el.className,
        html: el.outerHTML
      }));
      if (errorMessages.length > 0) {
        console.log('Found error messages:', errorMessages);
      }

      // Log the search input if it exists
      const searchInput = document.querySelector('input[type="search"], input[name*="search"], input[placeholder*="search"]');
      if (searchInput) {
        console.log('Search input found:', {
          value: searchInput.value,
          name: searchInput.name,
          placeholder: searchInput.placeholder,
          html: searchInput.outerHTML
        });
      } else {
        console.log('No search input found');
      }

      // Helper function to check if a title matches the card name
      function isExactCardMatch(title, cardName) {
        if (!title || !cardName) {
          console.log('Missing title or cardName:', { title, cardName });
          return false;
        }
        
        // Normalize both strings - only remove extra spaces and convert to lowercase
        const normalizeString = (str) => {
          return String(str).toLowerCase().trim()
            .replace(/\s+/g, ' ');  // Replace multiple spaces with single space
        };
        
        const normalizedTitle = normalizeString(title);
        const normalizedCardName = normalizeString(cardName);
        
        console.log('Detailed card name comparison:', {
          originalTitle: title,
          originalCardName: cardName,
          normalizedTitle,
          normalizedCardName,
          titleLength: normalizedTitle.length,
          cardNameLength: normalizedCardName.length,
          exactMatch: normalizedTitle === normalizedCardName
        });
        
        // First try exact match
        if (normalizedTitle === normalizedCardName) {
          console.log('Found exact match');
          return true;
        }
        
        // Then try match with strict word boundaries
        // This ensures we match the full card name as a distinct entity
        // and only at the start of the title or after a space/hyphen
        const regex = new RegExp(
          `(^|\\s|-)${normalizedCardName}(\\s|$|\\s*[-(])`,
          'i'
        );
        
        const isMatch = regex.test(normalizedTitle);
        console.log('Regex match details:', { 
          isMatch,
          matchIndex: normalizedTitle.search(regex),
          title: normalizedTitle,
          regexPattern: regex.toString()
        });
        
        return isMatch;
      }

      function extractNumericPrice(priceText) {
        if (!priceText) {
          console.log('No price text provided');
          return null;
        }
        
        console.log('Processing price text:', {
          original: priceText,
          cleaned: priceText.replace(/[^\d.]/g, ''),
          hasDollarSign: priceText.includes('$'),
          length: priceText.length
        });
        
        // Updated regex to handle prices with commas and optional decimal places
        const priceRegex = /\$[\d,]+(\.\d{2})?/;
        
        // Test if the price matches the pattern
        const matches = priceRegex.test(priceText);
        console.log('Price regex test:', {
          matches,
          pattern: priceRegex.toString(),
          testResult: matches ? 'matched' : 'no match',
          input: priceText
        });
        
        if (!matches) {
          console.log('No price pattern found in:', priceText);
          return null;
        }
        
        // Extract just the numeric part (remove $ and commas)
        const numericStr = priceText.replace(/[^\d.]/g, '');
        const result = parseFloat(numericStr);
        
        console.log('Price extraction result:', {
          numericStr,
          parsedResult: result,
          isNaN: isNaN(result),
          originalText: priceText,
          cleanedText: numericStr,
          validation: {
            isPositive: result > 0,
            isFinite: isFinite(result),
            isValid: result > 0 && isFinite(result)
          }
        });
        
        // Only return if we have a valid positive number
        if (isNaN(result) || !isFinite(result) || result <= 0) {
          console.log('Invalid price value:', result);
          return null;
        }
        
        return result;
      }

      // Wait for elements to be fully loaded
      function waitForElements() {
        return new Promise((resolve) => {
          let attempts = 0;
          // Get timeout from Ruby environment
          const isProduction = window.RUBY_ENV === 'production';
          const maxAttempts = isProduction ? 400 : 50; // 40 seconds in production, 5 seconds locally
          const stabilityWait = isProduction ? 20000 : 1000; // 20 seconds in production, 1 second locally
          
          const checkElements = () => {
            attempts++;
            const cards = document.querySelectorAll('.product-card__product');
            console.log(`Attempt ${attempts}: Found ${cards.length} cards`);
            
            if (cards.length > 0) {
              // Log details about each card found
              Array.from(cards).forEach((card, index) => {
                const title = card.querySelector('.product-card__title');
                const price = card.querySelector('.inventory__price-with-shipping');
                console.log(`Card ${index + 1} details:`, {
                  hasTitle: !!title,
                  titleText: title ? title.textContent.trim() : null,
                  hasPrice: !!price,
                  priceText: price ? price.textContent.trim() : null,
                  cardHTML: card.outerHTML
                });
              });
              
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
                }, stabilityWait);
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
        
        // Get all product cards - be more specific about what we're looking for
        const productCards = Array.from(document.querySelectorAll('.product-card__product, .product-card'));
        console.log(`Found ${productCards.length} product cards with specific selectors`);

        // Log the search results container first (and log the full outerHTML of the product card if it exists)
        const searchResults = document.querySelector('.search-results, [class*="search-results"]');
        console.log('Search results container:', searchResults ? {
          className: searchResults.className,
          childCount: searchResults.children.length,
          html: searchResults.outerHTML.slice(0, 500)
        } : 'Not found');
        const productCard = document.querySelector('.product-card__product');
        if (productCard) {
          console.log("Full outerHTML of product card (if any):", productCard.outerHTML);
        } else {
           console.log("No product card found (outerHTML not available).");
        }

        // Process each product card
        const validProducts = productCards.map((card, index) => {
          console.log(`\nProcessing card ${index + 1}:`);
          
          // Get elements using specific selectors first, then fall back to more general ones
          const titleElement = card.querySelector('.product-card__title') || 
                             card.querySelector('.product-card__name') ||
                             card.querySelector('[class*="product-card__title"]') ||
                             card.querySelector('[class*="product-card__name"]');
          
          const priceElement = card.querySelector('.inventory__price-with-shipping, .product-card__price, .price-point__price, [data-testid="product-price"]');
          
          const linkElement = card.querySelector('a[href*="/product"]');
          const setVariantElement = card.querySelector('.product-card__set-name__variant');
          const rarityElement = card.querySelector('.product-card__rarity__variant');

          // Log the card structure
          console.log('Card structure:', {
            className: card.className,
            childCount: card.children.length,
            hasTitle: !!titleElement,
            hasPrice: !!priceElement,
            hasLink: !!linkElement,
            hasSetVariant: !!setVariantElement,
            hasRarity: !!rarityElement,
            titleText: titleElement?.textContent?.trim(),
            priceText: priceElement?.textContent?.trim(),
            linkHref: linkElement?.href,
            setVariant: setVariantElement?.textContent?.trim(),
            rarity: rarityElement?.textContent?.trim(),
            titleHTML: titleElement?.outerHTML || null,
            priceHTML: priceElement?.outerHTML || null,
            linkHTML: linkElement?.outerHTML || null,
            html: card.outerHTML.slice(0, 500)
          });

          if (!titleElement || !priceElement || !linkElement) {
            console.log('Missing required elements in search result');
            return null;
          }

          // Get the text content and HTML - only after we know elements exist
          const title = titleElement.textContent.trim();
          const priceText = priceElement.textContent.trim();
          const titleHTML = titleElement.outerHTML;
          const priceHTML = priceElement.outerHTML;
          const linkHTML = linkElement.outerHTML;
          const url = linkElement.href;
          const setVariant = setVariantElement ? setVariantElement.textContent.trim() : '';
          const rarity = rarityElement ? rarityElement.textContent.trim() : '';
          
          console.log('Extracted content:', {
            title,
            priceText,
            setVariant,
            rarity,
            titleLength: title.length,
            priceTextLength: priceText.length
          });

          if (!title || !priceText) {
            console.log('Empty title or price text');
            return null;
          }

          // Skip art cards, proxies, tokens, and World Championship Decks
          if (title.toLowerCase().includes('art card') || 
              title.toLowerCase().includes('proxy') ||
              title.toLowerCase().includes('playtest') ||
              title.toLowerCase().includes('world championship decks') ||
              (setVariant && setVariant.toLowerCase().includes('world championship decks')) ||
              title.includes('(ALL)') ||
              (rarity && rarity.toLowerCase().includes('token'))) {
            console.log('Skipping non-playable card:', title, 
              setVariant ? `(Set: ${setVariant})` : '',
              rarity ? `(Rarity: ${rarity})` : '');
            return null;
          }

          // Extract numeric price
          const priceMatch = priceText.match(/\$([\d,]+\.\d{2})/);
          const price = priceMatch ? parseFloat(priceMatch[1].replace(/,/g, '')) : null;
          
          // Check if the card name matches
          const isMatch = isExactCardMatch(title, cardName);
          console.log('Card match result:', {
            title,
            cardName,
            isMatch,
            price,
            hasValidPrice: price !== null && price > 0
          });
          
          if (price !== null && price > 0 && isMatch) {
            return {
              title,
              titleHTML,
              price,
              priceHTML,
              url,
              linkHTML,
              setVariant,
              setVariantHTML: setVariantElement ? setVariantElement.outerHTML : 'No set variant element found',
              cardHTML: card.outerHTML
            };
          }

          return null;
        }).filter(Boolean);

        console.log(`Found ${validProducts.length} valid products after filtering`);

        if (validProducts.length === 0) {
          console.log('No valid products found. Card name:', cardName);
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
      // Only prevent navigation to actual error pages
      const errorUrls = [
        '/uhoh',
        '/error',
        '/500',
        '/404',
        '/maintenance',
        '/access-denied'
      ];
      
      // Helper to check if URL is an error page
      function isErrorUrl(url) {
        if (!url) return false;
        return errorUrls.some(errorPath => url.toLowerCase().includes(errorPath));
      }
      
      // Prevent navigation to error pages
      window.addEventListener('beforeunload', function(event) {
        const url = event.target.location?.href;
        if (isErrorUrl(url)) {
          console.log('Preventing navigation to error page:', url);
          event.preventDefault();
          event.stopPropagation();
          return false;
        }
      }, true);
      
      // Prevent clicks on price links from triggering searches
      document.addEventListener('click', function(event) {
        const link = event.target.closest('a');
        if (!link) return;
        
        // If it's an error page URL, prevent navigation
        if (isErrorUrl(link.href)) {
          console.log('Preventing click navigation to error page:', link.href);
          event.preventDefault();
          event.stopPropagation();
          return false;
        }
        
        // If it's a product link (contains /product/), allow it
        if (link.href.includes('/product/')) {
          console.log('Allowing navigation to product page:', link.href);
          return true;
        }
        
        // If it's a search link or any other link, prevent it
        if (link.href.includes('/search/') || link.href.includes('?q=')) {
          console.log('Preventing search navigation:', link.href);
          event.preventDefault();
          event.stopPropagation();
          return false;
        }
      }, true);
      
      // Also prevent form submissions that might trigger searches
      document.addEventListener('submit', function(event) {
        const form = event.target;
        if (form.action && (form.action.includes('/search/') || form.action.includes('?q='))) {
          console.log('Preventing search form submission:', form.action);
          event.preventDefault();
          event.stopPropagation();
          return false;
        }
      }, true);
      
      console.log('Added navigation prevention for searches and error pages');
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
        $file_logger.info("Request #{request_id}: Chosen Card:\nName: #{lowest_priced_product['title']}\nName Element: #{lowest_priced_product['titleHTML']}\nPrice: $#{lowest_priced_product['price']}\nPrice Element: #{lowest_priced_product['priceHTML']}\nURL: #{lowest_priced_product['url']}\nURL Element: #{lowest_priced_product['linkHTML']}\nSet Variant: #{lowest_priced_product['setVariant']}\nSet Variant Element: #{lowest_priced_product['setVariantHTML']}")
        if ENV['RACK_ENV'] == 'development'
          $file_logger.debug("Request #{request_id}: SEARCH RESULT ELEMENT: #{lowest_priced_product['cardHTML']}")
        end
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
      page.evaluate(REDIRECT_PREVENTION_JS)
      $file_logger.info("Request #{request_id}: Added redirect prevention")
    end
  end
end 