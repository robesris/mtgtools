require_relative 'logging'

module PriceProcessor
  def self.parse_base_price(price_text)
    return 0 unless price_text.is_a?(String)
    
    # Remove currency symbols and whitespace
    cleaned_price = price_text.gsub(/[^\d.]/, '').strip
    
    # Convert to cents
    begin
      (cleaned_price.to_f * 100).round
    rescue => e
      $logger.error("Error parsing price '#{price_text}': #{e.message}")
      0
    end
  end

  def self.calculate_shipping_price(listing)
    return 0 unless listing.is_a?(Hash)
    
    shipping_text = listing['shipping'] || listing[:shipping]
    return 0 unless shipping_text.is_a?(String)
    
    # Handle free shipping
    return 0 if shipping_text.downcase.include?('free')
    
    # Parse shipping price
    parse_base_price(shipping_text)
  end

  def self.total_price_str(base_price_cents, shipping_price_cents)
    total_cents = base_price_cents + shipping_price_cents
    dollars = total_cents / 100.0
    formatted = format('%.2f', dollars)
    # Remove any existing dollar signs and add a single one
    "$#{formatted.gsub(/^\$+/, '')}"
  end

  def self.format_prices(prices)
    formatted_prices = {}
    prices.each do |condition, data|
      # Ensure the price has a dollar sign and proper decimal format
      price_value = data['price'].to_s
      unless price_value.start_with?('$')
        # Convert to float and format with 2 decimal places
        price_float = price_value.gsub(/[^\d.]/, '').to_f
        price_value = format('$%.2f', price_float)
      end
      
      formatted_prices[condition] = {
        'price' => price_value,
        'url' => data['url']
      }
    end
    formatted_prices
  end
end 