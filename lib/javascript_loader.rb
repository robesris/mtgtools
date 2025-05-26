require 'json'
require 'fileutils'

module JavaScriptLoader
  def self.load_js_file(filename)
    js_path = File.join(File.dirname(__FILE__), 'javascript', filename)
    File.read(js_path)
  end

  def self.search_results
    js = File.read(File.join(File.dirname(__FILE__), 'javascript', 'search_results.js'))
    # Wrap the function in an IIFE that returns it
    "(function() { #{js}; return searchResults; })()"
  end

  def self.listings
    File.read(File.join(__dir__, 'javascript', 'listings.js'))
  end

  def self.redirect_prevention
    js = File.read(File.join(__dir__, 'javascript', 'redirect_prevention.js'))
    js.sub(/^module\.exports\s*=\s*/, '').strip
  end
end 