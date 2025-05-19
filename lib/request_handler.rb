require_relative 'logging'
require_relative 'browser_manager'
require_relative 'card_search'
require_relative 'legality_checker'
require_relative 'price_processor'
require_relative 'screenshot_manager'

class RequestHandler
  class << self
    def handle_request(card_name, request_id)
      begin
        # Check card legality first
        legality = LegalityChecker.check_legality(card_name, request_id)
        if legality == 'not_legal'
          $logger.info("Request #{request_id}: Card #{card_name} is not legal in any format")
          return {
            'success' => false,
            'error' => 'Card is not legal in any format'
          }
        end

        # Search for the card
        lowest_priced_product = CardSearch.search_card(card_name, request_id)
        if !lowest_priced_product
          $logger.error("Request #{request_id}: No valid products found for: #{card_name}")
          return {
            'success' => false,
            'error' => 'No valid products found'
          }
        end

        # Create a new page for condition processing
        condition_page = BrowserManager.create_page
        
        begin
          # Process each condition
          conditions = ['Near Mint', 'Lightly Played', 'Moderately Played', 'Heavily Played']
          prices = {}
          
          conditions.each do |condition|
            $logger.info("Request #{request_id}: Processing condition: #{condition}")
            result = CardSearch.process_condition(
              condition_page,
              lowest_priced_product['url'],
              condition,
              request_id,
              card_name
            )
            
            if result && result['success']
              prices[condition] = {
                'price' => result['price'],
                'url' => result['url']
              }
            end
          end

          if prices.empty?
            $logger.error("Request #{request_id}: No valid prices found for any condition")
            return {
              'success' => false,
              'error' => 'No valid prices found for any condition'
            }
          end

          # Format the prices
          formatted_prices = PriceProcessor.format_prices(prices)
          
          {
            'success' => true,
            'card_name' => card_name,
            'prices' => formatted_prices,
            'legality' => legality
          }
        ensure
          condition_page.close
        end
      rescue => e
        $logger.error("Request #{request_id}: Error handling request: #{e.message}")
        $logger.error(e.backtrace.join("\n"))
        {
          'success' => false,
          'error' => "Error processing request: #{e.message}"
        }
      end
    end
  end
end 