require 'bundler/setup'
require './price_proxy'

# Configure the application
set :port, ENV['PORT'] || 4567
set :bind, '0.0.0.0'
set :public_folder, File.join(File.dirname(__FILE__), 'commander_cards')
set :static, true
set :static_cache_control, [:public, :max_age => 300]

# Run our Sinatra application
run PriceProxyApp 