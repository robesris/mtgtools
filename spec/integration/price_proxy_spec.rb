require 'spec_helper'
require 'rack/test'
require 'capybara/rspec'
require 'capybara/dsl'
require 'selenium-webdriver'

RSpec.describe 'Price Proxy Integration' do
  include Capybara::DSL
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  before(:all) do
    # Configure Capybara
    Capybara.register_driver :selenium_chrome_headless do |app|
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument('--headless')
      options.add_argument('--no-sandbox')
      options.add_argument('--disable-dev-shm-usage')
      options.add_argument('--disable-gpu')
      options.add_argument('--window-size=1920,1080')
      
      Capybara::Selenium::Driver.new(
        app,
        browser: :chrome,
        options: options
      )
    end

    Capybara.default_driver = :selenium_chrome_headless
    Capybara.javascript_driver = :selenium_chrome_headless
    Capybara.server = :webrick
    Capybara.server_port = 4568  # Use a different port than the main app
  end

  before(:each) do
    # Start the server in a separate process
    @server_pid = Process.spawn('ruby price_proxy.rb -p 4567')
    sleep 2  # Give the server time to start
  end

  after(:each) do
    # Kill the server process
    Process.kill('TERM', @server_pid) if @server_pid
    Process.wait(@server_pid) rescue nil
  end

  it 'fetches card prices from TCGPlayer' do
    # Make a request to the card_info endpoint
    response = HTTParty.get(
      'http://localhost:4567/card_info',
      query: { card: 'Mox Diamond' }
    )

    expect(response.code).to eq(200)
    data = JSON.parse(response.body)
    
    # Verify the response structure
    expect(data).to have_key('prices')
    expect(data['prices']).to be_a(Hash)
    
    # Check that we got prices for both conditions
    expect(data['prices']).to have_key('Near Mint')
    expect(data['prices']).to have_key('Lightly Played')
    
    # Verify price format
    data['prices'].each do |condition, price_data|
      expect(price_data).to have_key('price')
      expect(price_data['price']).to match(/^\$\d+\.\d{2}$/)
      expect(price_data).to have_key('url')
      expect(price_data['url']).to include('tcgplayer.com')
    end
  end

  it 'handles invalid card names gracefully' do
    # Make a request with an invalid card name
    response = HTTParty.get(
      'http://localhost:4567/card_info',
      query: { card: 'Not A Real Card Name 123' }
    )

    expect(response.code).to eq(200)
    data = JSON.parse(response.body)
    
    # Verify error response
    expect(data).to have_key('error')
    expect(data['error']).to include('No valid product found')
  end
end 