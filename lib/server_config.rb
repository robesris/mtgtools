require 'sinatra'
require 'puppeteer-ruby'
require 'json'
require_relative 'logging'
require_relative 'config'

# Override Puppeteer's logger to reduce noise
class Puppeteer::Logger
  def warn(message)
    # Only show first line of WARN messages
    super(message.lines.first.chomp)
  end
end

# Override Sinatra's logger to reduce noise
class Sinatra::Logger
  def warn(message)
    # Only show first line of WARN messages
    super(message.lines.first.chomp)
  end
end

module ServerConfig
  def self.setup
    # Initialize logging (assign $file_logger)
    $file_logger = Logging.logger

    # Initialize configuration
    Config.setup

    # Log startup
    $file_logger.info("Starting server...")
  end
end 