module JavaScriptEvaluatorHeredocs
  def self.get_wait_for_elements_script
    <<~JS
      function() {
        const waitForElements = () => {
          const els = document.querySelectorAll("div[class*='product__price']");
          if (els.length > 0) {
            return els.length;
          }
          return 0;
        };
        return waitForElements();
      }
    JS
  end
end 