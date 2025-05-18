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

    # First check Scryfall for legality
    page.goto("https://scryfall.com/search?q=!#{URI.encode_www_form_component(card_name)}")
    page.wait_for_selector('.card-grid-item', timeout: 5000)
    
    # Click the first card to get to its page
    page.click('.card-grid-item')
    page.wait_for_selector('.card-details', timeout: 5000)

    # Get legality info
    legality = 'unknown'
    begin
      legality_section = page.query_selector('.card-legality')
      if legality_section
        commander_row = legality_section.query_selector('tr:has-text("Commander")')
        if commander_row
          legality = commander_row.query_selector('td:last-child').text.strip.downcase
        end
      end
    rescue => e
      puts "Error getting legality: #{e.message}"
    end

    # Get price info from TCGPlayer
    page.goto("https://www.tcgplayer.com/search/magic/product?q=#{URI.encode_www_form_component(card_name)}")
    page.wait_for_selector('.search-result', timeout: 5000)
    
    # Click the first result
    page.click('.search-result')
    page.wait_for_selector('.price-points', timeout: 5000)

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
      tcgplayer_url: page.url
    }.to_json

  rescue => e
    { error: e.message }.to_json
  ensure
    browser&.close
  end
end 