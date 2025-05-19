require 'puppeteer-ruby'
require_relative 'logging'

class BrowserManager
  class << self
    def get_browser
      if $browser.nil? || !$browser.connected?
        $logger.info("Initializing new browser instance")
        begin
          $browser = Puppeteer.launch(
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
              '--disable-features=site-per-process',
              '--disable-features=IsolateOrigins',
              '--disable-features=CrossSiteDocumentBlocking',
              '--disable-features=CrossSiteDocumentBlockingAlways',
              '--disable-blink-features=AutomationControlled',
              '--disable-automation',
              '--disable-infobars',
              '--lang=en-US,en',
              '--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
            ],
            ignore_default_args: ['--enable-automation']
          )
          
          # Set up global browser settings
          $browser.on('targetcreated') do |target|
            if target.type == 'page'
              begin
                page = target.page
                # Additional page setup can be added here
                $logger.debug("New page created in browser")
              rescue => e
                $logger.error("Error setting up new page: #{e.message}")
              end
            end
          end

          # Add browser disconnect handler
          $browser.on('disconnected') do
            $logger.warn("Browser disconnected, will reinitialize on next request")
            $browser = nil
          end

          # Verify browser is working by creating a test page
          test_page = $browser.new_page
          begin
            test_page.goto('about:blank')
            test_page.close
            $logger.info("Browser initialization verified with test page")
          rescue => e
            $logger.error("Browser verification failed: #{e.message}")
            cleanup_browser
            raise e
          end

          $logger.info("Browser initialized successfully")
        rescue => e
          $logger.error("Failed to initialize browser: #{e.message}")
          $logger.error(e.backtrace.join("\n"))
          cleanup_browser
          raise e
        end
      end
      $browser
    end

    def create_browser_context(request_id)
      browser = get_browser
      context = browser.create_incognito_browser_context
      
      # Track the context
      $browser_contexts[request_id] = {
        context: context,
        created_at: Time.now,
        pages: []
      }
      
      # Listen for target destruction to track when pages are closed
      context.on('targetdestroyed') do |target|
        if target.type == 'page'
          $logger.info("Request #{request_id}: Page destroyed in context")
          if $browser_contexts[request_id]
            $browser_contexts[request_id][:pages].delete_if { |page| page.target == target }
          end
        end
      end
      
      # Listen for target creation to track new pages
      context.on('targetcreated') do |target|
        if target.type == 'page'
          begin
            page = target.page
            if $browser_contexts[request_id]
              $browser_contexts[request_id][:pages] << page
              $logger.info("Request #{request_id}: New page created in context")
            end
          rescue => e
            $logger.error("Request #{request_id}: Error handling new page: #{e.message}")
          end
        end
      end
      
      context
    end

    def create_page
      browser = get_browser
      page = browser.new_page
      
      # Set up page-specific settings
      page.default_navigation_timeout = 30000  # 30 seconds
      page.default_timeout = 30000  # 30 seconds
      
      # Set up request interception
      page.request_interception = true
      
      # Add proper headers for TCGPlayer
      page.on('request') do |request|
        # Block iframe requests
        if request.frame && request.frame.parent_frame
          $logger.info("Blocking iframe request: #{request.url}")
          request.abort
          next
        end
        
        headers = request.headers.merge({
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
        })

        if request.navigation_request? && !request.redirect_chain.empty?
          if request.url.include?('uhoh')
            $logger.info("Preventing redirect to error page: #{request.url}")
            request.abort
          else
            $logger.info("Allowing redirect to: #{request.url}")
            request.continue(headers: headers)
          end
        else
          request.continue(headers: headers)
        end
      end

      # Add error handling
      page.on('error') do |err|
        $logger.error("Page error: #{err.message}")
      end

      # Add console logging
      page.on('console') do |msg|
        $logger.debug("Browser console: #{msg.text}")
      end

      page
    end

    def cleanup_browser
      if $browser
        begin
          $logger.info("Cleaning up browser...")
          $browser.close
          $logger.info("Browser closed successfully")
        rescue => e
          $logger.error("Error closing browser: #{e.message}")
        ensure
          $browser = nil
        end
      end
    end

    def cleanup_old_contexts
      $browser_contexts.delete_if do |_, context_data|
        if context_data[:created_at] < (Time.now - 600)  # 10 minutes
          begin
            context_data[:pages].each do |page|
              begin
                page.close
              rescue => e
                $logger.error("Error closing stale page: #{e.message}")
              end
            end
            context_data[:context].close
            true
          rescue => e
            $logger.error("Error cleaning up stale context: #{e.message}")
            true
          end
        else
          false
        end
      end
    end
  end
end 