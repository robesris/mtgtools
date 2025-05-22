require_relative 'logging'

module ScreenshotManager
  MAX_SCREENSHOTS = 3
  SCREENSHOT_INTERVAL = 2  # Take a screenshot every 2 seconds

  def self.take_screenshot(page, condition, screenshot_count, request_id)
    screenshot_path = "loading_sequence_#{condition}_#{screenshot_count}_#{Time.now.to_i}.png"
    page.screenshot(path: screenshot_path, full_page: true)
    $file_logger.info("Request #{request_id}: Saved screenshot #{screenshot_count} to #{screenshot_path}")
    screenshot_path
  end

  def self.log_listings_info(listings_html, request_id)
    return unless listings_html.is_a?(Hash) && listings_html['success']

    $file_logger.info("Request #{request_id}: === DETAILED LISTINGS INFO ===")
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

    $file_logger.info("=== END OF LISTINGS INFO ===")
  rescue => e
    $file_logger.error("Request #{request_id}: Error logging listings info: #{e.message}")
    $file_logger.error(e.backtrace.join("\n"))
  end

  def self.log_product_page_selectors(request_id)
    $file_logger.info("Request #{request_id}: Current product page selectors:")
    $file_logger.info("  Container: .listing-item")
    $file_logger.info("  Base Price: .listing-item__listing-data__info__price")
    $file_logger.info("  Shipping: .shipping-messages__price")
  end
end 