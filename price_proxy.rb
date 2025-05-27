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

  # Get both card legality and prices in a single request
  get '/card_info' do
    content_type :json
    card_name = params['card']
    request_id = SecureRandom.uuid
    $file_logger.info("Starting card info request #{request_id} for: #{card_name}")

    begin
      RequestHandler.handle_card_info_request(card_name, request_id)
    rescue ArgumentError => e
      { error: e.message }.to_json
    end
  end

  get '/' do
    content_type 'text/html'
    send_file File.join(settings.public_folder, 'commander_cards.html'), type: 'text/html'
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