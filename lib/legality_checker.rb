require 'httparty'
require 'json'
require_relative 'logging'

module LegalityChecker
  class << self
    def check_legality(card_name, request_id)
      begin
        $file_logger.info("Request #{request_id}: Checking legality with Scryfall")
        response = HTTParty.get("https://api.scryfall.com/cards/named?exact=#{CGI.escape(card_name)}")
        
        if response.success?
          legality_data = JSON.parse(response.body)
          legality = legality_data['legalities']['commander'] || 'unknown'
          $file_logger.info("Request #{request_id}: Legality for #{card_name}: #{legality}")
          return legality
        else
          $file_logger.error("Request #{request_id}: Scryfall API error: #{response.code} - #{response.body}")
          return 'unknown'
        end
      rescue => e
        $file_logger.error("Request #{request_id}: Error checking legality: #{e.message}")
        return 'unknown'
      end
    end
  end
end 