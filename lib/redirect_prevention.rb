require_relative 'logging'

module RedirectPrevention
  REDIRECT_PREVENTION_JS = <<~JS
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

  def self.add_prevention(page, request_id)
    begin
      page.evaluate(REDIRECT_PREVENTION_JS)
      $file_logger.info("Request #{request_id}: Added redirect prevention")
    rescue => e
      $file_logger.error("Request #{request_id}: Error adding redirect prevention: #{e.message}")
      $file_logger.error(e.backtrace.join("\n"))
    end
  end
end 