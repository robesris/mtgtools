require_relative 'logging'

module RateLimitHandler
  def self.handle_rate_limit(page, request_id)
    begin
      # Check if we're being rate limited using valid DOM selectors
      rate_limit_check = page.evaluate(<<~JS)
        function() {
          // Get all error messages
          const errorMessages = Array.from(document.querySelectorAll('.error-message, .rate-limit-message, [class*="error"], [class*="rate-limit"]'));
          
          // Check if any error message contains rate limit text
          const hasRateLimit = errorMessages.some(element => {
            const text = element.textContent.toLowerCase();
            return text.includes('rate limit') || text.includes('too many requests');
          });
          
          // Check for error pages
          const hasErrorPage = document.querySelector('.error-page, .uhoh-page, [class*="error-page"]') !== null;
          
          return {
            hasRateLimit,
            hasErrorPage,
            currentUrl: window.location.href,
            errorMessages: errorMessages.map(el => el.textContent.trim())
          };
        }
      JS
      
      if rate_limit_check['hasRateLimit'] || rate_limit_check['hasErrorPage']
        $file_logger.warn("Request #{request_id}: Rate limit detected, waiting...")
        $file_logger.info("Request #{request_id}: Error messages found: #{rate_limit_check['errorMessages'].inspect}")
        # Take a longer break if we hit rate limiting
        sleep(rand(10..15))
        # Try refreshing the page
        page.reload(wait_until: 'networkidle0')
        return true
      end
    rescue => e
      $file_logger.error("Request #{request_id}: Error checking rate limit: #{e.message}")
      $file_logger.error("Request #{request_id}: Rate limit check error details: #{e.backtrace.join("\n")}")
    end
    false
  end
end 