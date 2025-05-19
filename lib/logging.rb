require 'logger'

module Logging
  LOG_FILE = 'price_proxy.log'

  def self.setup
    # Clear log at start
    File.delete(LOG_FILE) if File.exist?(LOG_FILE)
    
    # Create logger
    logger = Logger.new(LOG_FILE)
    logger.level = Logger::INFO  # Only show INFO and above
    
    # Custom formatter to handle specific cases
    logger.formatter = proc do |severity, datetime, progname, msg|
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

    # Log startup message
    logger.info("=== Starting new price proxy server session ===")
    logger.info("Log file cleared and initialized")
    
    logger
  end
end 