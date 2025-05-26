require_relative 'logging'

module PageEvaluator
  def self.safe_evaluate(page, script, request_id = nil)
    begin
      result = page.evaluate(script)
      return result
    rescue => e
      $file_logger.error("Request #{request_id}: JavaScript evaluation error: #{e.message}")
      $file_logger.error("Request #{request_id}: Failed script: #{script}")
      return nil
    end
  end
end 