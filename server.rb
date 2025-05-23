require 'sinatra'
require 'sinatra/cors'
require 'puppeteer-ruby'
require 'json'

set :port, 4567
set :bind, '0.0.0.0'

configure do
  enable :cross_origin
end

options "*" do
  response.headers["Allow"] = "GET, POST, OPTIONS"
  response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, Accept, X-User-Email, X-Auth-Token"
  response.headers["Access-Control-Allow-Origin"] = "*"
  200
end

get '/card_info' do
  content_type :json
  card_name = params['name']
  
  return { error: 'No card name provided' }.to_json if card_name.nil?

  browser = nil
  begin
    browser = Puppeteer.launch(
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox']
    )
    page = browser.new_page

    # Get price and legality info from TCGPlayer
    page.goto("https://www.tcgplayer.com/search/magic/product?q=#{URI.encode_www_form_component(card_name)}")
    page.wait_for_selector('.search-result', timeout: 5000)
    
    # Click the first result
    page.click('.search-result')
    page.wait_for_selector('.price-points', timeout: 5000)

    # Get legality info
    legality = 'legal'  # Default to legal unless we find otherwise
    begin
      # Click the Legality tab in product details
      legality_tab = page.query_selector('button:has-text("Legality")')
      if legality_tab
        legality_tab.click
        page.wait_for_selector('.legality-table', timeout: 5000)
        
        # Find the Commander row in the legality table
        commander_row = page.query_selector('.legality-table tr:has-text("Commander")')
        if commander_row
          status = commander_row.query_selector('td:last-child')&.text&.strip&.downcase
          legality = status if status && status != 'legal'
        end
      end
    rescue => e
      puts "Error getting legality: #{e.message}"
    end

    # Get prices
    prices = {}
    begin
      price_points = page.query_selector_all('.price-points .price-point')
      price_points.each do |point|
        condition = point.query_selector('.condition')&.text&.strip&.downcase
        price = point.query_selector('.price')&.text&.strip
        if condition && price
          prices[condition] = price.gsub(/[^\d.]/, '')
        end
      end
    rescue => e
      puts "Error getting prices: #{e.message}"
    end

    {
      legality: legality,
      prices: prices,
      tcgplayer_url: page.url,
      timestamp: Time.now.to_i
    }.to_json

  rescue => e
    { error: e.message }.to_json
  ensure
    browser&.close
  end
end

# Add endpoint for caching prices
post '/cache_prices' do
  content_type :json
  request.body.rewind
  data = JSON.parse(request.body.read)
  
  card_name = data['card']
  prices = data['prices']
  timestamp = data['timestamp']
  
  return { error: 'Missing required fields' }.to_json unless card_name && prices && timestamp
  
  # Load existing cache
  cache_file = 'commander_card_prices.json'
  cache = if File.exist?(cache_file)
    JSON.parse(File.read(cache_file))
  else
    {}
  end
  
  # Update cache
  cache[card_name] = {
    'timestamp' => timestamp,
    'prices' => prices
  }
  
  # Save cache
  File.write(cache_file, JSON.pretty_generate(cache))
  
  { success: true }.to_json
rescue => e
  { error: e.message }.to_json
end 