require 'sinatra'
require 'sinatra/cross_origin'
require 'puppeteer-ruby'
require 'httparty'
require 'json'
require 'securerandom'
require_relative 'lib/logging'
require_relative 'lib/browser_manager'
require_relative 'lib/price_processor'
require_relative 'lib/price_extractor'
require_relative 'lib/request_tracker'
require_relative 'lib/config'
require_relative 'lib/page_manager'
require_relative 'lib/server_config'
require_relative 'lib/error_handler'
require_relative 'lib/rate_limit_handler'
require_relative 'lib/screenshot_manager'
require_relative 'lib/redirect_prevention'
require_relative 'lib/listing_evaluator'
require_relative 'lib/page_evaluator'

# Initialize server configuration and config before Sinatra settings
ServerConfig.setup

# Configure Sinatra settings
set :port, Config.settings[:port]
set :bind, Config.settings[:bind]
set :public_folder, Config.settings[:public_folder]

# Configure CORS
configure do
  enable :cross_origin
  set :allow_origin, "*"
  set :allow_methods, [:get, :post, :options]
  set :allow_credentials, true
  set :max_age, "1728000"
  set :expose_headers, ['Content-Type']
end

# Set up file logging first
$file_logger = Logging.logger
$file_logger.info("=== Starting new price proxy server session ===")
$file_logger.info("Log file cleared and initialized")

# Now initialize configuration
Config.setup

# Override Puppeteer's internal logging
module Puppeteer
  class Logger
    def warn(message)
      # Only show the first line of WARN messages
      message = message.split("\n").first if message.is_a?(String)
      super(message)
    end
  end
end

# Override Sinatra's default logger to handle WARN messages without backtraces
class Sinatra::Logger
  def warn(message)
    # Only show the first line of WARN messages
    message = message.split("\n").first if message.is_a?(String)
    super(message)
  end
end

# Handle shutdown signals
['INT', 'TERM'].each do |signal|
  Signal.trap(signal) do
    $file_logger.info("\nShutting down gracefully...")
    exit
  end
end

# Enable CORS
before do
  response.headers["Access-Control-Allow-Origin"] = "*"
  response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  response.headers["Access-Control-Allow-Headers"] = "Content-Type"
end

# Get both card legality and prices in a single request
get '/card_info' do
  content_type :json
  card_name = params['card']
  request_id = SecureRandom.uuid
  $file_logger.info("Starting card info request #{request_id} for: #{card_name}")
  
  if card_name.nil? || card_name.empty?
    ErrorHandler.handle_puppeteer_error(ArgumentError.new("No card name provided"), request_id, "Validation")
    return { error: 'No card name provided' }.to_json
  end

  # Use RequestTracker to handle request tracking
  tracking_result = RequestTracker.track_request(card_name, request_id)
  if tracking_result[:cached]
    return tracking_result[:data]
  end

  begin
    # Get legality from Scryfall first
    begin
      $file_logger.info("Request #{request_id}: Checking legality with Scryfall")
      legality_response = HTTParty.get("https://api.scryfall.com/cards/named?exact=#{CGI.escape(card_name)}")
      if legality_response.success?
        legality_data = JSON.parse(legality_response.body)
        legality = legality_data['legalities']['commander'] || 'unknown'
        $file_logger.info("Request #{request_id}: Legality for #{card_name}: #{legality}")
      else
        $file_logger.error("Request #{request_id}: Scryfall API error: #{legality_response.code} - #{legality_response.body}")
        legality = 'unknown'
      end
    rescue => e
      $file_logger.error("Request #{request_id}: Error checking legality: #{e.message}")
      legality = 'unknown'
    end

    # Use BrowserManager to get browser and context
    browser = BrowserManager.get_browser
    context = BrowserManager.create_browser_context(request_id)
    
    begin
      # Create a new page for the search
      search_page = context.new_page
      PageManager.configure_page(search_page, request_id)
      BrowserManager.add_page(request_id, search_page)
      
      # Navigate to TCGPlayer search
      $file_logger.info("Request #{request_id}: Navigating to TCGPlayer search for: #{card_name}")
      search_url = "https://www.tcgplayer.com/search/magic/product?q=#{CGI.escape(card_name)}&view=grid"
      search_page.goto(search_url, wait_until: 'networkidle0')
      
      # Add redirect prevention
      PriceExtractor.add_redirect_prevention(search_page, request_id)
      
      # Extract the lowest priced product
      lowest_priced_product = PriceExtractor.extract_lowest_priced_product(search_page, card_name, request_id)
      
      if !lowest_priced_product
        $file_logger.error("Request #{request_id}: No valid products found for: #{card_name}")
        return { error: 'No valid product found', legality: legality }.to_json
      end
      
      $file_logger.info("Request #{request_id}: Found lowest priced product: #{lowest_priced_product['title']} at $#{lowest_priced_product['price']}")
      
      # Now we only need to process the single lowest-priced product
      found_prices = false
      prices = {}
      found_conditions = 0
      conditions = ['Near Mint', 'Lightly Played']
      
      conditions.each do |condition|
        # Stop if we've found both conditions
        break if found_conditions >= 2
        
        # Create a new page for each condition
        condition_page = context.new_page
        PageManager.configure_page(condition_page, request_id)
        
        begin
          $file_logger.info("Request #{request_id}: Processing condition: #{condition}")
          
          # Navigate to the product page with condition filter
          condition_url = "#{lowest_priced_product['url']}?condition=#{CGI.escape(condition)}"
          condition_page.goto(condition_url, wait_until: 'networkidle0')
          
          # Add redirect prevention
          PriceExtractor.add_redirect_prevention(condition_page, request_id)
          
          # Extract prices from listings
          result = PriceExtractor.extract_listing_prices(condition_page, request_id)
          $file_logger.info("Request #{request_id}: Condition result: #{result.inspect}")
          
          if result && result.is_a?(Hash) && result['success']
            prices[condition] = {
              'price' => result['price'].to_s.gsub(/\$/,''),
              'url' => result['url']
            }
            found_conditions += 1
            found_prices = true
          end
        ensure
          condition_page.close
        end
      end
      
      if prices.empty?
        $file_logger.error("Request #{request_id}: No valid prices found for any condition")
        return { error: 'No valid prices found', legality: legality }.to_json
      end
      
      $file_logger.info("Request #{request_id}: Final prices: #{prices.inspect}")
      # Format the response to match the original style
      formatted_prices = PriceProcessor.format_prices(prices)
      
      # Combine prices and legality into a single response
      response = { 
        prices: formatted_prices,
        legality: legality
      }.to_json
      
      RequestTracker.cache_response(card_name, 'complete', response, request_id)
      response
      
    ensure
      # Clean up the context and its pages using BrowserManager
      BrowserManager.cleanup_context(request_id)
    end
    
  rescue => e
    ErrorHandler.handle_puppeteer_error(e, request_id, "Request processing")
    error_response = { 
      error: e.message,
      legality: legality
    }.to_json
    
    RequestTracker.cache_response(card_name, 'error', error_response, request_id)
    error_response
  end
end

# Process a single condition
def process_condition(page, product_url, condition, request_id, card_name)
  begin
    # Add redirect prevention
    RedirectPrevention.add_prevention(page, request_id)
    
    # Navigate to the product page with condition filter
    condition_param = URI.encode_www_form_component(condition)
    filtered_url = "#{product_url}#{product_url.include?('?') ? '&' : '?'}Condition=#{condition_param}&Language=English"
    $file_logger.info("Request #{request_id}: Navigating to filtered URL: #{filtered_url}")
    
    begin
      # Add random delay before navigation
      sleep(rand(2..4))
      
      # Navigate to the page with redirect prevention
      response = page.goto(filtered_url, 
        wait_until: 'domcontentloaded',
        timeout: 30000
      )
      
      # Check for rate limiting after navigation
      if RateLimitHandler.handle_rate_limit(page, request_id)
        # If we hit rate limiting, try one more time
        sleep(rand(5..10))
        response = page.goto(filtered_url, 
          wait_until: 'domcontentloaded',
          timeout: 30000
        )
      end
      
      # Start screenshot loop and price pattern search
      start_time = Time.now
      screenshot_count = 0
      last_screenshot_time = start_time

      # Take initial screenshot immediately after page load
      ScreenshotManager.take_screenshot(page, condition, screenshot_count, request_id)
      screenshot_count += 1
      last_screenshot_time = Time.now

      # Log our current selectors for the product page
      ScreenshotManager.log_product_page_selectors(request_id)

      # Main loop - continue until we hit max screenshots
      while screenshot_count < ScreenshotManager::MAX_SCREENSHOTS
        current_time = Time.now
        elapsed = current_time - start_time

        # Take screenshot every SCREENSHOT_INTERVAL seconds
        if (current_time - last_screenshot_time) >= ScreenshotManager::SCREENSHOT_INTERVAL
          begin
            ScreenshotManager.take_screenshot(page, condition, screenshot_count, request_id)
            screenshot_count += 1
            last_screenshot_time = current_time

            # Evaluate listings using the new module
            result = ListingEvaluator.evaluate_listings(page, request_id)
            
            # Log detailed info for the last screenshot
            if screenshot_count == ScreenshotManager::MAX_SCREENSHOTS && result['listings_html']
              ScreenshotManager.log_listings_info(result['listings_html'], request_id)
            end

            # If we found a valid price, return it immediately
            if result['success']
              $file_logger.info("Request #{request_id}: Breaking out of screenshot loop with price: #{result.inspect}")
              return result
            end
          rescue => e
            $file_logger.error("Request #{request_id}: Error taking screenshot: #{e.message}")
            # Still increment the counter to ensure we don't get stuck
            screenshot_count += 1
            last_screenshot_time = current_time
          end
        end

        # Small sleep to prevent tight loop
        sleep(0.1)
      end

      # If we get here, we didn't find a valid price in any screenshot
      $file_logger.error("Request #{request_id}: No valid listings found after all screenshots")
      return {
        'success' => false,
        'message' => 'No valid listings found after all screenshots'
      }

    rescue => e
      ErrorHandler.handle_puppeteer_error(e, request_id, "Condition processing")
      return {
        'success' => false,
        'message' => e.message
      }
    end
  end
end

# Clean up browser on server shutdown
# at_exit do
#   cleanup_browser
# end

get '/' do
  send_file File.join(settings.public_folder, 'commander_cards.html')
end

# Serve card images
get '/card_images/:filename' do
  send_file File.join(settings.public_folder, 'card_images', params[:filename])
end

# Serve JavaScript file
get '/card_prices.js' do
  content_type 'application/javascript'
  send_file File.join(settings.public_folder, 'card_prices.js')
end

# Add a method to handle Puppeteer errors consistently
def handle_puppeteer_error(e, request_id = nil, context = nil)
  # Log to file with full details
  $file_logger.error("Request #{request_id}: #{context} error: #{e.message}")
  $file_logger.debug("Request #{request_id}: #{context} error details: #{e.backtrace.join("\n")}")
  # Log to console without backtrace
  warn("Request #{request_id}: #{context} error: #{e.message}")
end

# Update error handling in the main request handler
get '/card_info' do
  content_type :json
  card_name = params['card']
  request_id = SecureRandom.uuid
  $file_logger.info("Starting card info request #{request_id} for: #{card_name}")
  
  if card_name.nil? || card_name.empty?
    ErrorHandler.handle_puppeteer_error(ArgumentError.new("No card name provided"), request_id, "Validation")
    return { error: 'No card name provided' }.to_json
  end

  # Use RequestTracker to handle request tracking
  tracking_result = RequestTracker.track_request(card_name, request_id)
  if tracking_result[:cached]
    return tracking_result[:data]
  end

  begin
    # Get legality from Scryfall first
    begin
      $file_logger.info("Request #{request_id}: Checking legality with Scryfall")
      legality_response = HTTParty.get("https://api.scryfall.com/cards/named?exact=#{CGI.escape(card_name)}")
      if legality_response.success?
        legality_data = JSON.parse(legality_response.body)
        legality = legality_data['legalities']['commander'] || 'unknown'
        $file_logger.info("Request #{request_id}: Legality for #{card_name}: #{legality}")
      else
        $file_logger.error("Request #{request_id}: Scryfall API error: #{legality_response.code} - #{legality_response.body}")
        legality = 'unknown'
      end
    rescue => e
      $file_logger.error("Request #{request_id}: Error checking legality: #{e.message}")
      legality = 'unknown'
    end

    # Use BrowserManager to get browser and context
    browser = BrowserManager.get_browser
    context = BrowserManager.create_browser_context(request_id)
    
    begin
      # Create a new page for the search
      search_page = context.new_page
      PageManager.configure_page(search_page, request_id)
      BrowserManager.add_page(request_id, search_page)
      
      # Navigate to TCGPlayer search
      $file_logger.info("Request #{request_id}: Navigating to TCGPlayer search for: #{card_name}")
      search_url = "https://www.tcgplayer.com/search/magic/product?q=#{CGI.escape(card_name)}&view=grid"
      search_page.goto(search_url, wait_until: 'networkidle0')
      
      # Add redirect prevention
      PriceExtractor.add_redirect_prevention(search_page, request_id)
      
      # Extract the lowest priced product
      lowest_priced_product = PriceExtractor.extract_lowest_priced_product(search_page, card_name, request_id)
        
        if !lowest_priced_product
        $file_logger.error("Request #{request_id}: No valid products found for: #{card_name}")
          return { error: 'No valid product found', legality: legality }.to_json
        end
        
      $file_logger.info("Request #{request_id}: Found lowest priced product: #{lowest_priced_product['title']} at $#{lowest_priced_product['price']}")
        
        # Now we only need to process the single lowest-priced product
        found_prices = false
        prices = {}
        found_conditions = 0
        conditions = ['Near Mint', 'Lightly Played']
        
        conditions.each do |condition|
          # Stop if we've found both conditions
          break if found_conditions >= 2
          
          # Create a new page for each condition
          condition_page = context.new_page
        PageManager.configure_page(condition_page, request_id)
        
        begin
          $file_logger.info("Request #{request_id}: Processing condition: #{condition}")
          
          # Navigate to the product page with condition filter
          condition_url = "#{lowest_priced_product['url']}?condition=#{CGI.escape(condition)}"
          condition_page.goto(condition_url, wait_until: 'networkidle0')
          
          # Add redirect prevention
          PriceExtractor.add_redirect_prevention(condition_page, request_id)
          
          # Extract prices from listings
          result = PriceExtractor.extract_listing_prices(condition_page, request_id)
          $file_logger.info("Request #{request_id}: Condition result: #{result.inspect}")
          
            if result && result.is_a?(Hash) && result['success']
              prices[condition] = {
              'price' => result['price'].to_s.gsub(/\$/,''),
                'url' => result['url']
              }
              found_conditions += 1
              found_prices = true
            end
          ensure
            condition_page.close
          end
        end
        
        if prices.empty?
        $file_logger.error("Request #{request_id}: No valid prices found for any condition")
          return { error: 'No valid prices found', legality: legality }.to_json
        end
        
      $file_logger.info("Request #{request_id}: Final prices: #{prices.inspect}")
        # Format the response to match the original style
      formatted_prices = PriceProcessor.format_prices(prices)
        
        # Combine prices and legality into a single response
        response = { 
          prices: formatted_prices,
          legality: legality
        }.to_json
        
      RequestTracker.cache_response(card_name, 'complete', response, request_id)
        response
        
      ensure
      # Clean up the context and its pages using BrowserManager
      BrowserManager.cleanup_context(request_id)
    end
    
          rescue => e
    ErrorHandler.handle_puppeteer_error(e, request_id, "Request processing")
      error_response = { 
        error: e.message,
      legality: legality
      }.to_json
      
    RequestTracker.cache_response(card_name, 'error', error_response, request_id)
      error_response
  end
end

# Update error handling in process_condition
def process_condition(page, product_url, condition, request_id, card_name)
  begin
    # Add redirect prevention
    RedirectPrevention.add_prevention(page, request_id)
    
    # Navigate to the product page with condition filter
    condition_param = URI.encode_www_form_component(condition)
    filtered_url = "#{product_url}#{product_url.include?('?') ? '&' : '?'}Condition=#{condition_param}&Language=English"
    $file_logger.info("Request #{request_id}: Navigating to filtered URL: #{filtered_url}")
    
    begin
      # Add random delay before navigation
      sleep(rand(2..4))
      
      # Navigate to the page with redirect prevention
      response = page.goto(filtered_url, 
        wait_until: 'domcontentloaded',
        timeout: 30000
      )
      
      # Check for rate limiting after navigation
      if RateLimitHandler.handle_rate_limit(page, request_id)
        # If we hit rate limiting, try one more time
        sleep(rand(5..10))
        response = page.goto(filtered_url, 
          wait_until: 'domcontentloaded',
          timeout: 30000
        )
      end
      
      # Start screenshot loop and price pattern search
      start_time = Time.now
      screenshot_count = 0
      last_screenshot_time = start_time

      # Take initial screenshot immediately after page load
      ScreenshotManager.take_screenshot(page, condition, screenshot_count, request_id)
      screenshot_count += 1
      last_screenshot_time = Time.now

      # Log our current selectors for the product page
      ScreenshotManager.log_product_page_selectors(request_id)

      # Main loop - continue until we hit max screenshots
      while screenshot_count < ScreenshotManager::MAX_SCREENSHOTS
        current_time = Time.now
        elapsed = current_time - start_time

        # Take screenshot every SCREENSHOT_INTERVAL seconds
        if (current_time - last_screenshot_time) >= ScreenshotManager::SCREENSHOT_INTERVAL
          begin
            ScreenshotManager.take_screenshot(page, condition, screenshot_count, request_id)
            screenshot_count += 1
            last_screenshot_time = current_time

            # Evaluate listings using the new module
            result = ListingEvaluator.evaluate_listings(page, request_id)
            
            # Log detailed info for the last screenshot
            if screenshot_count == ScreenshotManager::MAX_SCREENSHOTS && result['listings_html']
              ScreenshotManager.log_listings_info(result['listings_html'], request_id)
            end

            # If we found a valid price, return it immediately
            if result['success']
              $file_logger.info("Request #{request_id}: Breaking out of screenshot loop with price: #{result.inspect}")
              return result
            end
          rescue => e
            $file_logger.error("Request #{request_id}: Error taking screenshot: #{e.message}")
            # Still increment the counter to ensure we don't get stuck
            screenshot_count += 1
            last_screenshot_time = current_time
          end
        end

        # Small sleep to prevent tight loop
        sleep(0.1)
      end

      # If we get here, we didn't find a valid price in any screenshot
      $file_logger.error("Request #{request_id}: No valid listings found after all screenshots")
      return {
        'success' => false,
        'message' => 'No valid listings found after all screenshots'
      }

    rescue => e
      ErrorHandler.handle_puppeteer_error(e, request_id, "Condition processing")
      return {
        'success' => false,
        'message' => e.message
      }
    end
  end
end

# Update error handling in cleanup methods
def cleanup_browser_internal
  # Clean up all active contexts
  $browser_contexts.each do |request_id, context_data|
    begin
      $file_logger.info("Cleaning up browser context for request #{request_id}")
      context_data[:context].close if context_data[:context]
    rescue => e
      ErrorHandler.handle_puppeteer_error(e, request_id, "Context cleanup")
    ensure
      $browser_contexts.delete(request_id)
    end
  end
  
  if $browser
  begin
      $file_logger.info("Cleaning up browser...")
      $browser.close
  rescue => e
      ErrorHandler.handle_puppeteer_error(e, nil, "Browser cleanup")
    ensure
      $browser = nil
      # Force garbage collection
      GC.start
    end
  end
end

# Update page error handling
def setup_page_error_handling(page, request_id)
  page.on('error') do |err|
    ErrorHandler.handle_puppeteer_error(err, request_id, "Page")
  end

  page.on('console') do |msg|
    $file_logger.debug("Browser console: #{msg.text}")
  end
end

puts "Price proxy server starting on http://localhost:4568"
puts "Note: You need to install Chrome/Chromium for Puppeteer to work" 