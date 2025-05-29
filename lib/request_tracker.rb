require 'concurrent'
require 'securerandom'
require_relative 'logging'

module RequestTracker
  # Track active requests with concurrent handling
  @active_requests = Concurrent::Hash.new
  @request_mutex = Mutex.new
  @cache = Concurrent::Hash.new
  @cache_mutex = Mutex.new

  class << self
    def track_request(card_name, request_id)
      @request_mutex.synchronize do
        # Check if there's an active request for this card
        active_request = @active_requests[card_name]
        
        if active_request
          # If there's an active request, check its status
          if active_request[:status] == 'in_progress'
            # If it's still in progress, return the cached data if it exists
            cached_data = @cache[card_name]
            if cached_data && !cached_data.start_with?('{"error":')
              $file_logger.info("Request #{request_id}: Returning cached data for in-progress request: #{card_name}")
              return { cached: true, data: cached_data }
            end
          elsif active_request[:status] == 'complete'
            # If it's complete, return the cached data
            cached_data = @cache[card_name]
            if cached_data && !cached_data.start_with?('{"error":')
              $file_logger.info("Request #{request_id}: Returning cached data for completed request: #{card_name}")
              return { cached: true, data: cached_data }
            end
          end
          
          # If we get here, either the request failed or the cache is invalid
          # Clear the old request and cache
          @active_requests.delete(card_name)
          @cache.delete(card_name)
        end

        # Mark as in progress for new request
        mark_request_in_progress(card_name, request_id)
        { cached: false }
      end
    end

    def cache_response(card_name, status, data, request_id)
      @request_mutex.synchronize do
        @active_requests[card_name] = {
          status: status,
          data: data,
          timestamp: Time.now,
          request_id: request_id
        }
        
        # Only cache successful responses
        if status == 'complete' && !data.start_with?('{"error":')
          @cache[card_name] = data
          $file_logger.info("Request #{request_id}: Cached successful response for: #{card_name}")
        else
          # Clear any existing cache for failed requests
          @cache.delete(card_name)
          $file_logger.info("Request #{request_id}: Cleared cache for failed request: #{card_name}")
        end
      end
    end

    def cleanup_old_requests
      @request_mutex.synchronize do
        now = Time.now
        # Clear old requests (older than 5 minutes)
        @active_requests.delete_if do |_, request|
          request[:timestamp] < (now - 300)  # 5 minutes
        end
        
        # Clear old cache entries (older than 10 minutes)
        @cache.delete_if do |_, data|
          if data.is_a?(Hash) && data[:timestamp]
            data[:timestamp] < (now - 600)  # 10 minutes
          else
            false  # Keep entries without timestamps
          end
        end
      end
    end

    def get_request_status(card_name)
      @request_mutex.synchronize do
        @active_requests[card_name]
      end
    end

    private

    def mark_request_in_progress(card_name, request_id)
      @active_requests[card_name] = { 
        status: 'in_progress', 
        timestamp: Time.now,
        data: nil,
        request_id: request_id
      }
      $file_logger.info("Request #{request_id}: Marked request as in progress for: #{card_name}")
    end
  end
end 