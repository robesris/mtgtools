require_relative 'logging'

class PriceProcessor
  class << self
    def calculate_shipping_price(listing)
      return 0 unless listing.is_a?(Hash)
      return 0 unless listing['shipping'].is_a?(Hash)
      return 0 unless listing['shipping']['text'].is_a?(String)
      
      shipping_text = listing['shipping']['text'].strip.downcase
      
      # Check for free shipping indicators
      return 0 if shipping_text.include?('free shipping') ||
                  shipping_text.include?('shipping included') ||
                  shipping_text.include?('free shipping over')
      
      # Look for shipping cost pattern
      if shipping_text =~ /\+\s*\$(\d+\.?\d*)\s*shipping/i
        # Convert to cents
        (Regexp.last_match(1).to_f * 100).round
      else
        0
      end
    end

    def total_price_str(base_price_cents, shipping_price_cents)
      total_cents = base_price_cents + shipping_price_cents
      # Return just the numeric value with 2 decimal places, no dollar sign
      format('%.2f', total_cents / 100.0)
    end

    def parse_base_price(price_text)
      return 0 unless price_text.is_a?(String)
      
      # Extract numeric price and convert to cents
      if price_text =~ /\$(\d+\.?\d*)/
        (Regexp.last_match(1).to_f * 100).round
      else
        0
      end
    end

    def format_prices(prices)
      formatted_prices = {}
      prices.each do |condition, data|
        # Extract just the numeric price from the price text, but preserve the $ prefix
        price_value = data['price'].gsub(/[^\d.$]/, '')  # Keep $ and decimal point
        formatted_prices[condition] = {
          'price' => "#{price_value}",
          'url' => data['url']
        }
      end
      formatted_prices
    end
  end
end 