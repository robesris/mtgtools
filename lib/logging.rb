require 'logger'

module Logging
  LOG_FILE = 'price_proxy.log'

  def self.create_formatter
    proc do |severity, datetime, progname, msg|
      # Skip certain non-critical warnings
      if severity == 'WARN' && msg.is_a?(String)
        # List of warning messages we want to suppress
        suppressed_warnings = [
          'Frame not found during evaluation',
          'Protocol error',
          'Target closed',
          'Target destroyed',
          'No target with given id found',
          'Frame was detached',
          'Frame was removed',
          'Frame was not found'
        ]
        
        # Skip if this is a suppressed warning
        return nil if suppressed_warnings.any? { |w| msg.include?(w) }

        # For WARN level, only show the first line of the message
        # This removes any backtrace or additional context
        msg = msg.split("\n").first if msg.include?("\n")
      end
      
      # Truncate everything after the error message when it contains a Ruby object dump
      formatted_msg = if msg.is_a?(String)
        if msg.include?('#<')
          # Keep everything up to and including the error message, then add truncation
          msg.split(/#</).first.strip + " ...truncated..."
        else
          msg
        end
      else
        msg.to_s.split(/#</).first.strip + " ...truncated..."
      end
      
      # Only log if we haven't suppressed the message
      "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{formatted_msg}\n" if formatted_msg
    end
  end

  def self.setup_logger
    # Clear log file at start
    File.delete(LOG_FILE) if File.exist?(LOG_FILE)

    # Create formatter
    formatter = create_formatter

    # Set up file logger
    file_logger = Logger.new(LOG_FILE)
    file_logger.level = Logger::INFO
    file_logger.formatter = formatter

    # Set up console logger
    console_logger = Logger.new(STDOUT)
    console_logger.level = Logger::INFO
    console_logger.formatter = formatter

    # Create a multi-logger that writes to both
    MultiLogger.new(file_logger, console_logger)
  end

  def self.logger
    @logger ||= setup_logger
  end

  # A simple logger that writes to multiple loggers
  class MultiLogger
    def initialize(*loggers)
      @loggers = loggers
    end

    def method_missing(method_name, *args, &block)
      @loggers.each do |logger|
        logger.send(method_name, *args, &block) if logger.respond_to?(method_name)
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      @loggers.any? { |logger| logger.respond_to?(method_name, include_private) }
    end
  end
end 