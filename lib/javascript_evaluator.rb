require_relative 'logging'

module JavaScriptEvaluator
  class << self
    def load_script(filename)
      script_path = File.join(File.dirname(__FILE__), 'javascript', filename)
      File.read(script_path)
    rescue => e
      $file_logger.error("Failed to load JavaScript file #{filename}: #{e.message}")
      raise
    end

    def evaluate(page, script_name, params = nil, request_id, operation)
      begin
        $file_logger.debug("Request #{request_id}: Evaluating JavaScript for #{operation}")
        $file_logger.debug("Request #{request_id}: Parameters: #{params.inspect}") if params
        
        script = load_script(script_name)
        result = page.evaluate(script, params&.to_json)
        
        if result.nil?
          $file_logger.error("Request #{request_id}: JavaScript evaluation returned nil for #{operation}")
          return nil
        end
        
        $file_logger.debug("Request #{request_id}: JavaScript evaluation result for #{operation}: #{result.inspect}")
        result
      rescue => e
        $file_logger.error("Request #{request_id}: JavaScript evaluation error in #{operation}: #{e.message}")
        $file_logger.error("Request #{request_id}: Error backtrace: #{e.backtrace.join("\n")}")
        $file_logger.error("Request #{request_id}: Failed script: #{script}")
        nil
      end
    end
  end
end 