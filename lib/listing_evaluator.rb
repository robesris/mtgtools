require_relative 'logging'

module ListingEvaluator
  LISTING_EVALUATION_JS = <<~'JS'
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
        base_price = PriceProcessor.parse_base_price(listings_html['listings'][0]['basePrice']['text'])
        shipping_price = PriceProcessor.calculate_shipping_price(listings_html['listings'][0])
        $file_logger.info("Request #{request_id}: Found valid price: $#{base_price}")
        
        {
          'success' => true,
          'price' => PriceProcessor.total_price_str(base_price, shipping_price).gsub(/[^\d.]/, ''),
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