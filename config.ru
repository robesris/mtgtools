require './price_proxy'

# Configure the application
set :port, ENV['PORT'] || 4567
set :bind, '0.0.0.0'

# Run the Sinatra application
run Sinatra::Application 