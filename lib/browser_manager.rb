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
          headless: false,
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
        setup_browser_event_handlers
        
        # Create a test page to resize the browser
        test_page = @browser.new_page
        begin
          PageManager.configure_page(test_page)
          
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

    # Create a new page with proper settings
    def create_page
      browser = get_browser
      page = browser.new_page
      PageManager.configure_page(page)
      page
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

    # Track a new context
    def track_context(request_id, context)
      @browser_contexts[request_id] = {
        context: context,
        created_at: Time.now,
        pages: []
      }
    end

    # Add a page to a context's tracking
    def add_page(request_id, page)
      if @browser_contexts[request_id]
        @browser_contexts[request_id][:pages] << page
      end
    end

    # Remove a page from a context's tracking
    def remove_page(request_id, target)
      if @browser_contexts[request_id]
        @browser_contexts[request_id][:pages].delete_if { |page| page.target == target }
      end
    end

    # Clean up a specific context and its pages
    def cleanup_context(request_id)
      if @browser_contexts[request_id]
        begin
          # Close all pages in the context
          @browser_contexts[request_id][:pages].each do |page|
            begin
              page.close
            rescue => e
              handle_puppeteer_error(e, request_id, "Page cleanup")
            end
          end
          
          # Close the context
          @browser_contexts[request_id][:context].close
          $file_logger.info("Request #{request_id}: Closed browser context and pages")
        rescue => e
          handle_puppeteer_error(e, request_id, "Context cleanup")
        ensure
          @browser_contexts.delete(request_id)
        end
      end
    end

    # Clean up old contexts (older than 10 minutes)
    def cleanup_old_contexts
      @browser_contexts.delete_if do |request_id, context_data|
        if context_data[:created_at] < (Time.now - 600)  # 10 minutes
          begin
            # Close any remaining pages
            context_data[:pages].each do |page|
              begin
                page.close
              rescue => e
                handle_puppeteer_error(e, request_id, "Stale page cleanup")
              end
            end
            # Close the context
            context_data[:context].close
            $file_logger.info("Cleaned up stale context for request #{request_id}")
          rescue => e
            handle_puppeteer_error(e, request_id, "Stale context cleanup")
          end
          true
        else
          false
        end
      end
    end

    private

    def setup_browser_event_handlers
      @browser.on('targetcreated') do |target|
        if target.type == 'page'
          begin
            page = target.page
            PageManager.configure_page(page)
            
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
    end

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