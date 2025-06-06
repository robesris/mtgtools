require 'bundler/setup'
require './price_proxy'

# Get absolute path to public folder
PUBLIC_FOLDER = File.expand_path('commander_cards', __dir__)
puts "Public folder path: #{PUBLIC_FOLDER}"
puts "Public folder exists? #{File.exist?(PUBLIC_FOLDER)}"
puts "HTML file exists? #{File.exist?(File.join(PUBLIC_FOLDER, 'commander_cards.html'))}"
puts "Card images folder exists? #{File.exist?(File.join(PUBLIC_FOLDER, 'card_images'))}"
puts "Sample image exists? #{File.exist?(File.join(PUBLIC_FOLDER, 'card_images', '479531.jpg'))}"

# Configure the application
set :port, ENV['PORT'] || 4567
set :bind, '0.0.0.0'
set :public_folder, PUBLIC_FOLDER
set :static, true
set :static_cache_control, [:public, :max_age => 300]
set :root, __dir__  # Set the root directory to the current directory

# Run our Sinatra application
run PriceProxyApp 