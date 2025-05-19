require_relative 'logging'

class RateLimiter
  class << self
    def handle_rate_limit(page, request_id)
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
          $logger.warn("Request #{request_id}: Rate limit detected, waiting...")
          $logger.info("Request #{request_id}: Error messages found: #{rate_limit_check['errorMessages'].inspect}")
          # Take a longer break if we hit rate limiting
          sleep(rand(10..15))
          # Try refreshing the page
          page.reload(wait_until: 'networkidle0')
          return true
        end
      rescue => e
        $logger.error("Request #{request_id}: Error checking rate limit: #{e.message}")
        $logger.error("Request #{request_id}: Rate limit check error details: #{e.backtrace.join("\n")}")
      end
      false
    end

    def add_redirect_prevention(page, request_id)
      page.evaluate(<<~JS)
        function() {
          // Store original navigation methods
          const originalPushState = history.pushState;
          const originalReplaceState = history.replaceState;
          
          // Override history methods to prevent redirects to error page
          history.pushState = function(state, title, url) {
            if (typeof url === 'string' && url.includes('uhoh')) {
              console.log('Prevented history push to error page');
              return;
            }
            return originalPushState.apply(this, arguments);
          };

          history.replaceState = function(state, title, url) {
            if (typeof url === 'string' && url.includes('uhoh')) {
              console.log('Prevented history replace to error page');
              return;
            }
            return originalReplaceState.apply(this, arguments);
          };

          // Add navigation listener
          window.addEventListener('beforeunload', (event) => {
            if (window.location.href.includes('uhoh')) {
              console.log('Prevented navigation to error page');
              event.preventDefault();
              event.stopPropagation();
              return false;
            }
          });

          // Add click interceptor for links that might redirect
          document.addEventListener('click', (event) => {
            const link = event.target.closest('a');
            if (link && link.href && link.href.includes('uhoh')) {
              console.log('Prevented click navigation to error page');
              event.preventDefault();
              event.stopPropagation();
              return false;
            }
          }, true);

          console.log('Redirect prevention initialized');
        }
      JS
    end
  end
end 