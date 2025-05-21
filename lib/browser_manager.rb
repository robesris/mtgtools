require 'puppeteer-ruby'
require 'concurrent'
require_relative 'logging'

module BrowserManager
  # Global browser instance and context tracking
  @browser = nil
  @browser_contexts = Concurrent::Hash.new  # Track active contexts
  @browser_mutex = Mutex.new
  @browser_retry_count = 0
  MAX_RETRIES = 3
  SESSION_TIMEOUT = 1800  # 30 minutes

  class << self
    attr_reader :browser_contexts

    # Get or initialize browser
    def get_browser
      if @browser.nil? || !@browser.connected?
        $file_logger.info("Initializing new browser instance")
        @browser = Puppeteer.launch(
          headless: true,
          args: [
            '--no-sandbox',
            '--disable-setuid-sandbox',
            '--disable-dev-shm-usage',
            '--disable-accelerated-2d-canvas',
            '--disable-gpu',
            '--window-size=1920,1080',
            '--disable-web-security',
            '--disable-features=IsolateOrigins,site-per-process',
            '--disable-features=site-per-process',  # Disable site isolation
            '--disable-features=IsolateOrigins',    # Disable origin isolation
            '--disable-features=CrossSiteDocumentBlocking',  # Disable cross-site blocking
            '--disable-features=CrossSiteDocumentBlockingAlways',  # Disable cross-site blocking
            '--disable-blink-features=AutomationControlled',
            '--disable-automation',
            '--disable-infobars',
            '--lang=en-US,en',
            '--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
          ],
          ignore_default_args: ['--enable-automation']
        )
        
        # Set up global browser settings
        @browser.on('targetcreated') do |target|
          if target.type == 'page'
            begin
              page = target.page
              
              # Set viewport size for each new page
              page.client.send_message('Emulation.setDeviceMetricsOverride', {
                width: 3000,
                height: 2000,
                deviceScaleFactor: 1,
                mobile: false
              })

              # Dispatch a window resize event to trigger layout reflow
              page.evaluate('window.dispatchEvent(new Event("resize"))')
              
              # Disable frame handling for this page
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
              
              # Set timeouts for each new page
              page.set_default_navigation_timeout(30000)  # 30 seconds
              page.set_default_timeout(30000)  # 30 seconds
              
              # Add a small random delay before each navigation
              page.on('request') do |request|
                if request.navigation_request?
                  # Block iframe requests
                  if request.frame && request.frame.parent_frame
                    $file_logger.info("Blocking iframe request: #{request.url}")
                    request.abort
                    next
                  end
                  sleep(rand(1..3))
                end
              end

              # Add error handling for page crashes
              page.on('error') do |err|
                $file_logger.error("Page error: #{err.message}")
              end

              # Add console logging
              page.on('console') do |msg|
                $file_logger.debug("Browser console: #{msg.text}")
              end
              
              # Log the viewport size after setting it
              actual_viewport = page.evaluate(<<~JS)
                function() {
                  return {
                    windowWidth: window.innerWidth,
                    windowHeight: window.innerHeight,
                    devicePixelRatio: window.devicePixelRatio,
                    screenWidth: window.screen.width,
                    screenHeight: window.screen.height,
                    viewportWidth: document.documentElement.clientWidth,
                    viewportHeight: document.documentElement.clientHeight
                  };
                }
              JS
              $file_logger.info("New page viewport after resize: #{actual_viewport.inspect}")
            rescue => e
              $file_logger.error("Error setting up new page: #{e.message}")
            end
          end
        end

        # Create a test page to resize the browser
        test_page = @browser.new_page
        begin
          # Use CDP to set a large viewport
          test_page.client.send_message('Emulation.setDeviceMetricsOverride', {
            width: 3000,
            height: 2000,
            deviceScaleFactor: 1,
            mobile: false
          })
          
          # Verify the viewport size
          actual_viewport = test_page.evaluate(<<~JS)
            function() {
              return {
                windowWidth: window.innerWidth,
                windowHeight: window.innerHeight,
                devicePixelRatio: window.devicePixelRatio,
                screenWidth: window.screen.width,
                screenHeight: window.screen.height,
                viewportWidth: document.documentElement.clientWidth,
                viewportHeight: document.documentElement.clientHeight
              };
            }
          JS
          $file_logger.info("Browser viewport after resize: #{actual_viewport.inspect}")
        ensure
          test_page.close
        end
      end
      @browser
    end

    # Add a method to create a new context with proper tracking
    def create_browser_context(request_id)
      browser = get_browser
      context = browser.create_incognito_browser_context
      
      # Track the context
      @browser_contexts[request_id] = {
        context: context,
        created_at: Time.now,
        pages: []
      }
      
      # Listen for target destruction to track when pages are closed
      context.on('targetdestroyed') do |target|
        if target.type == 'page'
          $file_logger.info("Request #{request_id}: Page destroyed in context")
          # Remove the page from our tracking if it exists
          if @browser_contexts[request_id]
            @browser_contexts[request_id][:pages].delete_if { |page| page.target == target }
          end
        end
      end
      
      # Listen for target creation to track new pages
      context.on('targetcreated') do |target|
        if target.type == 'page'
          begin
            page = target.page
            if @browser_contexts[request_id]
              @browser_contexts[request_id][:pages] << page
              $file_logger.info("Request #{request_id}: New page created in context")
              setup_page_error_handling(page, request_id)
            end
          rescue => e
            handle_puppeteer_error(e, request_id, "Page creation")
          end
        end
      end
      
      context
    end

    # Cleanup browser without mutex lock
    def cleanup_browser_internal
      # Clean up all active contexts
      @browser_contexts.each do |request_id, context_data|
        begin
          $file_logger.info("Cleaning up browser context for request #{request_id}")
          context_data[:context].close if context_data[:context]
        rescue => e
          handle_puppeteer_error(e, request_id, "Context cleanup")
        ensure
          @browser_contexts.delete(request_id)
        end
      end
      
      if @browser
        begin
          $file_logger.info("Cleaning up browser...")
          @browser.close
        rescue => e
          handle_puppeteer_error(e, nil, "Browser cleanup")
        ensure
          @browser = nil
          # Force garbage collection
          GC.start
        end
      end
    end

    # Cleanup browser with mutex lock
    def cleanup_browser
      @browser_mutex.synchronize do
        cleanup_browser_internal
      end
    end

    private

    def setup_page_error_handling(page, request_id)
      # Add error handling for page crashes
      page.on('error') do |err|
        $file_logger.error("Request #{request_id}: Page error: #{err.message}")
      end

      # Add console logging
      page.on('console') do |msg|
        $file_logger.debug("Request #{request_id}: Browser console: #{msg.text}")
      end
    end

    def handle_puppeteer_error(e, request_id = nil, context = nil)
      # Log to file with full details
      $file_logger.error("Request #{request_id}: #{context} error: #{e.message}")
      $file_logger.debug("Request #{request_id}: #{context} error details: #{e.backtrace.join("\n")}")
      # Log to console without backtrace
      warn("Request #{request_id}: #{context} error: #{e.message}")
    end
  end
end 