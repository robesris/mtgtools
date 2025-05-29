require 'concurrent'
require 'securerandom'
require_relative 'logging'

module RequestTracker
  # Track active requests with concurrent handling
  @active_requests = Concurrent::Hash.new
  @request_mutex = Mutex.new

  class << self
    def track_request(card_name, request_id)
      @request_mutex.synchronize do
        cached_request = @active_requests[card_name]
        return handle_cached_request(cached_request, card_name) if cached_request

        # Mark as in progress if no cached request exists
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
      end
    end

    def cleanup_old_requests
      @request_mutex.synchronize do
        # Clear old requests (older than 5 minutes)
        @active_requests.delete_if do |_, request|
          request[:timestamp] < (Time.now - 300)  # 5 minutes
        end
      end
    end

    def get_request_status(card_name)
      @request_mutex.synchronize do
        @active_requests[card_name]
      end
    end

    private

    def handle_cached_request(cached_request, card_name)
      cached = cache.get(card_name)
      if cached
         # If the cached status is 'error' (or if the cache is stale (older than 10 minutes)), do not return a cached error.
         # (In our case, we assume that if the cached value is a JSON string starting with '{"error":' then it is an error.)
         if cached.start_with?('{"error":') || (cache.ttl(card_name) && cache.ttl(card_name) < 600)
            $file_logger.info("Request #{request_id}: Ignoring cached error (or stale cache) for #{card_name} (TTL: #{cache.ttl(card_name)})")
            cache.delete(card_name)
            cache.set(card_name, nil, expires_in: 600) # (10 minutes) (or use a shorter TTL if desired)
            return { cached: false }
         end
         $file_logger.info("Request #{request_id}: Returning cached (non-error) data for #{card_name}")
         return { cached: true, data: cached }
      end
      cache.set(card_name, nil, expires_in: 600) # (10 minutes) (or use a shorter TTL if desired)
      { cached: false }
    end

    def mark_request_in_progress(card_name, request_id)
      @active_requests[card_name] = { 
        status: 'in_progress', 
        timestamp: Time.now,
        data: nil,
        request_id: request_id
      }
    end
  end
end 