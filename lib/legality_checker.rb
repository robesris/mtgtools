require 'net/http'
require 'json'
require_relative 'logging'

class LegalityChecker
  class << self
    def check_legality(card_name, request_id)
      begin
        $logger.info("Request #{request_id}: Checking legality with Scryfall")
        
        # Normalize card name for API request
        normalized_name = card_name.strip.gsub(/\s+/, '+')
        uri = URI("https://api.scryfall.com/cards/named?exact=#{normalized_name}")
        
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          card_data = JSON.parse(response.body)
          
          # Check if the card is legal in any format
          legal_formats = card_data['legalities'].select { |_, status| status == 'legal' }.keys
          
          if legal_formats.any?
            $logger.info("Request #{request_id}: Legality for #{card_name}: legal")
            'legal'
          else
            $logger.info("Request #{request_id}: Legality for #{card_name}: not legal")
            'not legal'
          end
        else
          $logger.error("Request #{request_id}: Scryfall API error: #{response.code} #{response.message}")
          'unknown'
        end
      rescue => e
        $logger.error("Request #{request_id}: Error checking legality: #{e.message}")
        'unknown'
      end
    end
  end
end 