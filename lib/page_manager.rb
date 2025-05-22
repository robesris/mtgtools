require_relative 'logging'

module PageManager
  TCGPLAYER_HEADERS = {
    'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
    'Accept-Language' => 'en-US,en;q=0.9',
    'Accept-Encoding' => 'gzip, deflate, br',
    'Connection' => 'keep-alive',
    'Upgrade-Insecure-Requests' => '1',
    'Sec-Fetch-Dest' => 'document',
    'Sec-Fetch-Mode' => 'navigate',
    'Sec-Fetch-Site' => 'none',
    'Sec-Fetch-User' => '?1',
    'Cache-Control' => 'max-age=0'
  }.freeze

  class << self
    def configure_page(page, request_id = nil)
      # Set viewport
      page.viewport = Puppeteer::Viewport.new(
        width: 1920,
        height: 1080,
        device_scale_factor: 1,
        is_mobile: false,
        has_touch: false,
        is_landscape: true
      )

      # Set timeouts using assignment operator
      page.default_navigation_timeout = 30000  # 30 seconds
      page.default_timeout = 30000  # 30 seconds

      # Set up request interception
      page.request_interception = true

      # Add request handling
      setup_request_handling(page, request_id)

      # Add error handling
      setup_error_handling(page, request_id)

      # Disable frame handling
      disable_frame_handling(page)

      page
    end

    private

    def setup_request_handling(page, request_id)
      page.on('request') do |request|
        # Block iframe requests
        if request.frame && request.frame.parent_frame
          $file_logger.info("Request #{request_id}: Blocking iframe request: #{request.url}")
          request.abort
          next
        end

        headers = request.headers.merge(TCGPLAYER_HEADERS)

        if request.navigation_request? && !request.redirect_chain.empty?
          # Only prevent redirects to error pages
          if request.url.include?('uhoh')
            $file_logger.info("Request #{request_id}: Preventing redirect to error page: #{request.url}")
            request.abort
          else
            $file_logger.info("Request #{request_id}: Allowing redirect to: #{request.url}")
            request.continue(headers: headers)
          end
        else
          # Allow all other requests, including API calls
          request.continue(headers: headers)
        end
      end
    end

    def setup_error_handling(page, request_id)
      page.on('error') do |err|
        $file_logger.error("Request #{request_id}: Page error: #{err.message}")
      end

      page.on('console') do |msg|
        $file_logger.debug("Request #{request_id}: Browser console: #{msg.text}")
      end
    end

    def disable_frame_handling(page)
      page.evaluate(<<~JS)
        function() {
          // Disable iframe creation
          const originalCreateElement = document.createElement;
          document.createElement = function(tagName) {
            if (tagName.toLowerCase() === 'iframe') {
              console.log('Prevented iframe creation');
              return null;
            }
            return originalCreateElement.apply(this, arguments);
          };
          
          // Block frame navigation
          window.addEventListener('beforeunload', (event) => {
            if (window !== window.top) {
              event.preventDefault();
              event.stopPropagation();
              return false;
            }
          }, true);
          
          // Block frame creation via innerHTML
          const originalInnerHTML = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
          Object.defineProperty(Element.prototype, 'innerHTML', {
            set: function(value) {
              if (typeof value === 'string' && value.includes('<iframe')) {
                console.log('Prevented iframe creation via innerHTML');
                return;
              }
              originalInnerHTML.set.call(this, value);
            },
            get: originalInnerHTML.get
          });
        }
      JS
    end
  end
end 