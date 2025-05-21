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
        # Check if this card is already being processed
        cached_request = @active_requests[card_name]
        if cached_request
          if cached_request[:status] == 'complete'
            $file_logger.info("Returning cached response for #{card_name}")
            return { cached: true, data: cached_request[:data] }
          elsif cached_request[:status] == 'error'
            $file_logger.info("Returning cached error for #{card_name}")
            return { cached: true, data: cached_request[:data] }
          end
        end

        # Mark as in progress
        @active_requests[card_name] = { 
          status: 'in_progress', 
          timestamp: Time.now,
          data: nil,
          request_id: request_id
        }

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
  end
end 