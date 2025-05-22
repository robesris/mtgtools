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

    private

    BROWSER_LAUNCH_ARGS = [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-accelerated-2d-canvas',
      '--disable-gpu',
      '--window-size=1920,1080',
      '--disable-web-security',
      '--disable-features=IsolateOrigins,site-per-process',
      '--disable-features=site-per-process',
      '--disable-features=IsolateOrigins',
      '--disable-features=CrossSiteDocumentBlocking',
      '--disable-features=CrossSiteDocumentBlockingAlways',
      '--disable-blink-features=AutomationControlled',
      '--disable-automation',
      '--disable-infobars',
      '--lang=en-US,en',
      '--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
    ].freeze

    VIEWPORT_CHECK_JS = <<~JS.freeze
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

    def safe_page_operation(page, request_id, operation)
      yield
    rescue => e
      handle_puppeteer_error(e, request_id, operation)
      nil
    end

    def safe_context_operation(context_data, request_id, operation)
      yield
    rescue => e
      handle_puppeteer_error(e, request_id, operation)
    ensure
      @browser_contexts.delete(request_id) if operation.include?('cleanup')
    end

    def close_pages(pages, request_id, operation)
      pages.each do |page|
        safe_page_operation(page, request_id, "#{operation} page") do
          page.close
        end
      end
    end

    def create_context_data(context)
      {
        context: context,
        created_at: Time.now,
        pages: []
      }
    end

    def setup_target_handlers(context, request_id)
      context.on('targetdestroyed') do |target|
        remove_page(request_id, target) if target.type == 'page'
      end

      context.on('targetcreated') do |target|
        if target.type == 'page'
          safe_page_operation(target.page, request_id, "Page creation") do
            page = target.page
            if @browser_contexts[request_id]
              @browser_contexts[request_id][:pages] << page
              $file_logger.info("Request #{request_id}: New page created in context")
              setup_page_error_handling(page, request_id)
            end
          end
        end
      end
    end

    public

    def get_browser
      if @browser.nil? || !@browser.connected?
        $file_logger.info("Initializing new browser instance")
        @browser = Puppeteer.launch(
          headless: true,
          args: BROWSER_LAUNCH_ARGS,
          ignore_default_args: ['--enable-automation']
        )
        
        setup_browser_event_handlers
        verify_browser_viewport
      end
      @browser
    end

    def create_browser_context(request_id)
      browser = get_browser
      context = browser.create_incognito_browser_context
      
      @browser_contexts[request_id] = create_context_data(context)
      setup_target_handlers(context, request_id)
      context
    end

    def cleanup_browser_internal
      @browser_contexts.each do |request_id, context_data|
        safe_context_operation(context_data, request_id, "Context cleanup") do
          $file_logger.info("Cleaning up browser context for request #{request_id}")
          context_data[:context].close if context_data[:context]
        end
      end
      
      if @browser
        safe_context_operation(nil, nil, "Browser cleanup") do
          $file_logger.info("Cleaning up browser...")
          @browser.close
        end
        @browser = nil
        GC.start
      end
    end

    def cleanup_browser
      @browser_mutex.synchronize do
        cleanup_browser_internal
      end
    end

    def track_context(request_id, context)
      @browser_contexts[request_id] = create_context_data(context)
    end

    def add_page(request_id, page)
      @browser_contexts[request_id]&.dig(:pages)&.push(page)
    end

    def remove_page(request_id, target)
      @browser_contexts[request_id]&.dig(:pages)&.delete_if { |page| page.target == target }
    end

    def cleanup_context(request_id)
      return unless (context_data = @browser_contexts[request_id])

      safe_context_operation(context_data, request_id, "Context cleanup") do
        close_pages(context_data[:pages], request_id, "Context")
        context_data[:context].close
        $file_logger.info("Request #{request_id}: Closed browser context and pages")
      end
    end

    def cleanup_old_contexts
      @browser_contexts.delete_if do |request_id, context_data|
        if context_data[:created_at] < (Time.now - 600)  # 10 minutes
          safe_context_operation(context_data, request_id, "Stale context cleanup") do
            close_pages(context_data[:pages], request_id, "Stale")
            context_data[:context].close
            $file_logger.info("Cleaned up stale context for request #{request_id}")
          end
          true
        else
          false
        end
      end
    end

    private

    def verify_browser_viewport
      test_page = @browser.new_page
      begin
        PageManager.configure_page(test_page)
        actual_viewport = test_page.evaluate(VIEWPORT_CHECK_JS)
        $file_logger.info("Browser viewport after resize: #{actual_viewport.inspect}")
      ensure
        test_page.close
      end
    end

    def setup_browser_event_handlers
      @browser.on('targetcreated') do |target|
        if target.type == 'page'
          safe_page_operation(target.page, nil, "New page setup") do
            page = target.page
            PageManager.configure_page(page)
            actual_viewport = page.evaluate(VIEWPORT_CHECK_JS)
            $file_logger.info("New page viewport after resize: #{actual_viewport.inspect}")
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