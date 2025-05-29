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
        # Check if there's an active request for this card
        active_request = @active_requests[card_name]
        
        if active_request && active_request[:status] == 'in_progress'
          # If there's an in-progress request, wait for it to complete
          $file_logger.info("Request #{request_id}: Request already in progress for: #{card_name}")
          return { cached: false }
        end
        
        # Clear any existing request and start a new one
        @active_requests.delete(card_name)
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
        $file_logger.info("Request #{request_id}: Updated request status to #{status} for: #{card_name}")
      end
    end

    def cleanup_old_requests
      @request_mutex.synchronize do
        now = Time.now
        # Clear old requests (older than 5 minutes)
        @active_requests.delete_if do |_, request|
          request[:timestamp] < (now - 300)  # 5 minutes
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