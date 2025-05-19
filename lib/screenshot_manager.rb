require 'fileutils'
require_relative 'logging'

class ScreenshotManager
  class << self
    def take_screenshot(page, prefix, count, timestamp, logger, request_id)
      begin
        filename = "#{prefix}_#{timestamp}_#{count}.png"
        page.screenshot(path: filename)
        logger.info("Request #{request_id}: Took screenshot #{count}: #{filename}")
        filename
      rescue => e
        logger.error("Request #{request_id}: Error taking screenshot: #{e.message}")
        nil
      end
    end

    def take_error_screenshot(page, card_name, timestamp, logger, request_id)
      begin
        filename = "error_#{card_name.gsub(/\s+/, '_')}_#{timestamp}.png"
        page.screenshot(path: filename)
        logger.info("Request #{request_id}: Took error screenshot: #{filename}")
        filename
      rescue => e
        logger.error("Request #{request_id}: Error taking error screenshot: #{e.message}")
        nil
      end
    end

    def delete_all_screenshots
      Dir.glob("*.png").each do |file|
        begin
          File.delete(file)
        rescue => e
          $logger.error("Error deleting screenshot #{file}: #{e.message}")
        end
      end
    end
  end
end 