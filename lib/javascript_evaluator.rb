require_relative 'javascript_evaluator_heredocs'

module JavaScriptEvaluator
  def self.wait_for_elements(page, request_id)
    $file_logger.debug("Waiting for elements to load", request_id: request_id)
    page.evaluate(JavaScriptLoader.search_results)
    page.evaluate(get_wait_for_elements_script)
  end

  def self.process_cards(page, card_name, request_id)
    js = JavaScriptLoader.load_js_file('search_results.js')
    escaped_card_name = card_name.gsub("\\", "\\\\").gsub("'", "\\'")
    script = "function() { #{js}; return searchResults({ cardName: '#{escaped_card_name}' }); }"
    begin
      result = page.evaluate(script)
      $file_logger.info("Direct function definition result: #{result.inspect}", request_id: request_id)
    rescue => e
      $file_logger.error("Direct function definition error: #{e.message}", request_id: request_id)
      result = { error: e.message }
    end
    result
  end
end 