source 'https://rubygems.org'

ruby '3.4.3'  # Upgraded for Render deployment (latest supported)

gem 'nokogiri', '~> 1.15'
gem 'httparty', '~> 0.21.0'
gem 'csv', '~> 3.2'
gem 'rtesseract', '~> 3.1'  # Use latest available version for OCR
gem 'rmagick', '~> 5.3'          # For image processing
gem 'down', '~> 5.4'             # For downloading images
gem 'sinatra'
gem 'sinatra-cross_origin'
gem 'puma'  # Production-grade web server for Sinatra 
gem "rackup", "~> 2.2"
gem 'puppeteer-ruby', '~> 0.45.6'  # For browser automation in price scraping
gem 'concurrent-ruby', '~> 1.2'  # For parallel processing
gem 'json'
gem 'pry'

group :test do
  gem 'rspec', '~> 3.12'
  gem 'rack-test', '~> 2.1'
  gem 'capybara', '~> 3.39'
  gem 'selenium-webdriver', '~> 4.10'
end
