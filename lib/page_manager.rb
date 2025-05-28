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
      return if page.closed?

      begin
        # Set viewport
        page.viewport = Puppeteer::Viewport.new(
          width: 1920,
          height: 1080,
          device_scale_factor: 1,
          is_mobile: false,
          has_touch: false,
          is_landscape: true
        )

        # Set default navigation timeout
        default_timeout = ENV['RACK_ENV'] == 'production' ? 120000 : 30000  # 2 minutes in production, 30 seconds locally
        page.default_navigation_timeout = default_timeout
        page.default_timeout = default_timeout
        $file_logger.info("Request #{request_id}: Set default navigation timeout to #{default_timeout}ms")

        # Set up request handling with less restrictions
        setup_request_handling(page, request_id)

        # Add error handling
        setup_error_handling(page, request_id)

        # Log page configuration
        $file_logger.info("Request #{request_id}: Page configured with viewport: #{page.viewport.inspect}")

        page
      rescue => e
        $file_logger.error("Request #{request_id}: Error configuring page: #{e.message}")
        raise
      end
    end

    private

    def setup_request_handling(page, request_id)
      page.request_interception = true
      
      page.on('request') do |request|
        # Only block iframes that are not from TCGPlayer
        if request.frame && request.frame.parent_frame && !request.url.include?('tcgplayer.com')
          $file_logger.info("Request #{request_id}: Blocking non-TCGPlayer iframe: #{request.url}")
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
          # Allow all other requests
          request.continue(headers: headers)
        end
      end

      # Add response logging
      page.on('response') do |response|
        if response.url.include?('tcgplayer.com')
          $file_logger.info("Request #{request_id}: Response from #{response.url}: #{response.status}")
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

      page.on('pageerror') do |err|
        $file_logger.error("Request #{request_id}: Page JavaScript error: #{err.message}")
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