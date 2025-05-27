require './price_proxy'

# Configure the application
set :port, ENV['PORT'] || 4567
set :bind, '0.0.0.0'
set :public_folder, 'commander_cards'

# Run our Sinatra application
run PriceProxyApp 