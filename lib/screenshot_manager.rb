require 'fileutils'

module ScreenshotManager
  def self.delete_all_screenshots
    # Delete both types of screenshots
    Dir.glob('screenshot*.png').each { |f| File.delete(f) }
    Dir.glob('loading_sequence*.png').each { |f| File.delete(f) }
  end

  def self.take_screenshot(page, prefix, count, timestamp, logger, request_id = nil)
    screenshot_path = "#{prefix}_#{count}_#{timestamp}.png"
    begin
      page.screenshot(path: screenshot_path, full_page: true)
      logger.info("Request #{request_id}: Saved screenshot to #{screenshot_path}")
      screenshot_path
    rescue => e
      logger.error("Request #{request_id}: Error taking screenshot: #{e.message}")
      nil
    end
  end

  def self.take_error_screenshot(page, card_name, timestamp, logger, request_id = nil)
    screenshot_path = "search_error_#{timestamp}.png"
    begin
      page.screenshot(path: screenshot_path)
      logger.info("Request #{request_id}: Saved error screenshot for #{card_name} to #{screenshot_path}")
      screenshot_path
    rescue => e
      logger.error("Request #{request_id}: Error taking error screenshot: #{e.message}")
      nil
    end
  end
end 