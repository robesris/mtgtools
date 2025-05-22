require_relative 'logging'

module PageEvaluator
  def self.safe_evaluate(page, script, request_id = nil, context = nil)
    begin
      # Add a small delay to ensure the page is ready
      sleep(0.1) if page.url.include?('tcgplayer.com')
      
      # Evaluate the script and capture any console output
      console_output = []
      page.on('console') do |msg|
        console_output << msg.text if msg.type == 'log' || msg.type == 'error'
      end
      
      result = page.evaluate(script)
      
      # Log console output if any was captured
      if console_output.any?
        $file_logger.debug("Request #{request_id}: JavaScript console output for #{context}: #{console_output.join("\n")}")
      end
      
      if result.nil?
        $file_logger.warn("Request #{request_id}: JavaScript evaluation returned nil for #{context}")
        return nil
      end
      
      result
    rescue => e
      error_message = "Request #{request_id}: JavaScript evaluation error for #{context}: #{e.message}"
      $file_logger.error(error_message)
      $file_logger.error("Request #{request_id}: Failed script: #{script}")
      $file_logger.error("Request #{request_id}: Error backtrace: #{e.backtrace.join("\n")}")
      
      # Try to get more context about the page state
      begin
        page_state = page.evaluate(<<~JS)
          function() {
            return {
              url: window.location.href,
              readyState: document.readyState,
              title: document.title,
              hasError: document.querySelector('.error-page, .uhoh-page') !== null,
              hasRateLimit: document.querySelector('[class*="rate-limit"], [class*="error"]') !== null
            }
          }
        JS
        $file_logger.error("Request #{request_id}: Page state at error: #{page_state.inspect}")
      rescue => state_error
        $file_logger.error("Request #{request_id}: Could not get page state: #{state_error.message}")
      end
      
      nil
    end
  end
end 