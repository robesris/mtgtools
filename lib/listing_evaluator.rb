require_relative 'logging'

module ListingEvaluator
  LISTING_EVALUATION_JS = <<~'JS'
    function() {
      try {
        // Find all listing items
        var listingItems = document.querySelectorAll('.listing-item');
        var listings = [];
        
        // Log the total number of listings found
        console.log('Total listings found:', listingItems.length);
        
        // First, collect all listings for logging
        listingItems.forEach(function(item, index) {
          // Log all possible price elements for debugging
          var allPriceElements = item.querySelectorAll('[class*="price"]');
          console.log('Listing', index + 1, 'price elements:', Array.from(allPriceElements).map(el => ({
            className: el.className,
            text: el.textContent.trim(),
            html: el.outerHTML
          })));
          
          var basePrice = item.querySelector('.listing-item__listing-data__info__price');
          var shipping = item.querySelector('.shipping-messages__price');
          
          // Log if we found the expected elements
          console.log('Listing', index + 1, 'element search:', {
            foundBasePrice: !!basePrice,
            foundShipping: !!shipping,
            basePriceClass: basePrice ? basePrice.className : null,
            shippingClass: shipping ? shipping.className : null
          });
          
          listings.push({
            index: index,
            containerClasses: item.className,
            basePrice: basePrice ? {
              text: basePrice.textContent.trim(),
              classes: basePrice.className,
              html: basePrice.outerHTML  // Include full HTML for debugging
            } : null,
            shipping: shipping ? {
              text: shipping.textContent.trim(),
              classes: shipping.className,
              html: shipping.outerHTML  // Include full HTML for debugging
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
                price: (price + shippingPrice).toFixed(2),
                basePrice: price.toFixed(2),
                shippingPrice: shippingPrice.toFixed(2),
                url: window.location.href,
                details: {
                  basePrice: price.toFixed(2),
                  shippingPrice: shippingPrice.toFixed(2),
                  shippingText: shippingText,
                  shippingElement: shipping ? shipping.outerHTML : null
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

  def self.evaluate_listings(page, request_id)
    begin
      listings_html = page.evaluate(LISTING_EVALUATION_JS)
      
      if listings_html.is_a?(Hash) && listings_html['success'] && listings_html['listings'][0]
        # Log the full HTML of the first listing for debugging
        $file_logger.info("Request #{request_id}: === FULL LISTING HTML ===")
        $file_logger.info(listings_html['listings'][0]['html'])
        $file_logger.info("=== END FULL LISTING HTML ===")
        
        # Log the exact text content we're getting
        $file_logger.info("Request #{request_id}: === EXACT TEXT CONTENT ===")
        $file_logger.info("Base price element text: #{listings_html['listings'][0]['basePrice']['text']}")
        $file_logger.info("Shipping element text: #{listings_html['listings'][0]['shipping']&.dig('text')}")
        $file_logger.info("=== END EXACT TEXT CONTENT ===")
        
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
          'url' => page.url,
          'listings_html' => listings_html  # Include the full listings data for logging
        }
      else
        {
          'success' => false,
          'message' => listings_html['message'] || 'No valid listings found'
        }
      end
    rescue => e
      $file_logger.error("Request #{request_id}: Error evaluating listings: #{e.message}")
      $file_logger.error(e.backtrace.join("\n"))
      {
        'success' => false,
        'message' => e.message
      }
    end
  end
end 