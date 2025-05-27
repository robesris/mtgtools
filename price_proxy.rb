require_relative 'lib/price_extractor'
require_relative 'lib/price_processor'

require 'sinatra'
require 'sinatra/cross_origin'
require 'puppeteer-ruby'
require 'httparty'
require 'json'
require 'securerandom'
require_relative 'lib/logging'
require_relative 'lib/browser_manager'
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
require_relative 'lib/legality_checker'
require_relative 'lib/request_handler'

# Initialize server configuration and config before Sinatra settings
ServerConfig.setup

# Define our Sinatra application
class PriceProxyApp < Sinatra::Base
  # Set the root directory
  set :root, File.dirname(__FILE__)
  set :public_folder, File.join(File.dirname(__FILE__), 'commander_cards')

  # Configure CORS
  configure do
    enable :cross_origin
    set :allow_origin, "*"
    set :allow_methods, [:get, :post, :options]
    set :allow_credentials, true
    set :max_age, "1728000"
    set :expose_headers, ['Content-Type']
  end

  # Enable CORS
  before do
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
  end

  # Handle OPTIONS requests for CORS preflight
  options '/card_info' do
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    response.headers["Access-Control-Max-Age"] = "1728000"
    200
  end

  # Get both card legality and prices in a single request
  post '/card_info' do
    content_type :json
    
    # Parse JSON request body
    begin
      request_payload = JSON.parse(request.body.read)
      card_name = request_payload['card']
    rescue JSON::ParserError => e
      $file_logger.error("Invalid JSON payload: #{e.message}")
      status 400
      return { error: "Invalid JSON payload" }.to_json
    end

    request_id = SecureRandom.uuid
    $file_logger.info("Starting card info request #{request_id} for: #{card_name}")

    begin
      RequestHandler.handle_card_info_request(card_name, request_id)
    rescue ArgumentError => e
      status 400
      { error: e.message }.to_json
    rescue => e
      status 500
      { error: "Internal server error" }.to_json
    end
  end

  get '/' do
    content_type 'text/html'
    html_path = File.join(settings.root, 'commander_cards', 'commander_cards.html')
    $file_logger.info("Attempting to serve HTML file from: #{html_path}")
    $file_logger.info("File exists? #{File.exist?(html_path)}")
    if File.exist?(html_path)
      send_file html_path, type: 'text/html'
    else
      $file_logger.error("HTML file not found at: #{html_path}")
      status 404
      "File not found: #{html_path}"
    end
  end

  # Serve card images
  get '/card_images/:filename' do
    # Use the public folder path from settings
    image_path = File.join(settings.public_folder, 'card_images', params[:filename])
    $file_logger.info("Attempting to serve image from: #{image_path}")
    $file_logger.info("Image exists? #{File.exist?(image_path)}")
    $file_logger.info("Public folder: #{settings.public_folder}")
    if File.exist?(image_path)
      content_type 'image/jpeg'
      send_file image_path
    else
      $file_logger.error("Image not found at: #{image_path}")
      status 404
      "Image not found: #{params[:filename]}"
    end
  end

  # Serve JavaScript file
  get '/card_prices.js' do
    content_type 'application/javascript'
    js_path = File.join(settings.root, 'commander_cards', 'card_prices.js')
    send_file js_path
  end
end

# Set up file logging
$file_logger = Logging.logger
$file_logger.info("=== Starting new price proxy server session ===")
$file_logger.info("Log file cleared and initialized")

# Initialize configuration
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

puts "Price proxy server starting on http://localhost:#{ENV['PORT'] || 4567}"
puts "Note: You need to install Chrome/Chromium for Puppeteer to work" 

# Run the app with correct host/port for local and Render
if __FILE__ == $0
  PriceProxyApp.run!({
    host: '0.0.0.0',
    port: ENV.fetch('PORT', 4567)
  })
end 