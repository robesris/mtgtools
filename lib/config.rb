require 'optparse'

module Config
  class << self
    def setup
      parse_options
      setup_debug_mode
      setup_global_variables
    end

    def settings
      {
        port: @options[:port] || 4567,
        bind: '0.0.0.0',
        public_folder: 'commander_cards'
      }
    end

    private

    def parse_options
      @options = {}
      OptionParser.new do |opts|
        opts.banner = "Usage: ruby price_proxy.rb [options]"
        opts.on("-p", "--port PORT", "Port to run the server on") do |port|
          @options[:port] = port.to_i
        end
      end.parse!
    end

    def setup_debug_mode
      @debug_mode = ENV['DEBUG_MODE'] == 'true'
      $file_logger.info("Debug mode environment variable: #{ENV['DEBUG_MODE'].inspect}")
      $file_logger.info("Debug mode enabled: #{@debug_mode}")

      if @debug_mode
        $file_logger.info("Debug mode enabled - screenshots will be saved to debug_screenshots/")
        FileUtils.mkdir_p('debug_screenshots')
        if File.directory?('debug_screenshots') && File.writable?('debug_screenshots')
          $file_logger.info("Debug screenshots directory is ready")
        else
          $file_logger.error("Debug screenshots directory is not writable!")
        end
      end
    end

    def setup_global_variables
      # Global browser instance and context tracking
      $browser = nil
      $browser_contexts = Concurrent::Hash.new
      $browser_mutex = Mutex.new
      $browser_retry_count = 0
      $MAX_RETRIES = 3
      $SESSION_TIMEOUT = 1800  # 30 minutes

      # Add request tracking with concurrent handling
      $active_requests = Concurrent::Hash.new
      $request_mutex = Mutex.new

      # Make debug mode accessible globally
      $DEBUG_MODE = @debug_mode
    end
  end
end 