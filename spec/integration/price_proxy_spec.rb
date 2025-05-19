require 'spec_helper'
require 'rack/test'
require_relative '../../price_proxy'

RSpec.describe 'Price Proxy Integration', type: :integration do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  before(:all) do
    # Start the server in a separate thread
    @server_thread = Thread.new do
      Sinatra::Application.run!(port: 4567, bind: '0.0.0.0')
    end
    # Give the server time to start
    sleep 2
  end

  after(:all) do
    # Clean up the server thread
    @server_thread.exit if @server_thread
  end

  describe 'GET /card_info' do
    let(:card_name) { 'The Tabernacle at Pendrell Vale' }
    let(:expected_prices) do
      {
        'Lightly Played' => {
          'price' => '$2100.00',
          'url' => a_string_matching(%r{https://www\.tcgplayer\.com/product/\d+/.*Condition=Lightly%20Played})
        },
        'Near Mint' => {
          'price' => '$2899.99',
          'url' => a_string_matching(%r{https://www\.tcgplayer\.com/product/\d+/.*Condition=Near%20Mint})
        }
      }
    end

    it 'returns correct prices for The Tabernacle' do
      # Make the request to our proxy server
      get "/card_info?card=#{URI.encode_www_form_component(card_name)}"
      
      # Verify response status
      expect(last_response.status).to eq(200)
      
      # Parse the JSON response
      response_data = JSON.parse(last_response.body)
      
      # Verify we have prices
      expect(response_data).to have_key('prices')
      expect(response_data['prices']).to be_a(Hash)
      
      # Verify each condition's price and URL
      expected_prices.each do |condition, expected_data|
        expect(response_data['prices']).to have_key(condition)
        actual_data = response_data['prices'][condition]
        
        # Verify price format
        expect(actual_data['price']).to eq(expected_data['price'])
        
        # Verify URL format
        expect(actual_data['url']).to match(expected_data['url'])
      end

      # Verify the rendered HTML format
      # First, get the card info page
      get '/'
      expect(last_response.status).to eq(200)
      
      # Then make a request to load the prices
      get "/card_info?card=#{URI.encode_www_form_component(card_name)}"
      expect(last_response.status).to eq(200)
      
      # Parse the response and verify the price format
      response_data = JSON.parse(last_response.body)
      prices = response_data['prices']
      
      # Construct the expected HTML format
      expected_html = "Lightly Played: <a href=\"#{prices['Lightly Played']['url']}\" target=\"_blank\" class=\"price-link\">$2,100.00</a> | Near Mint: <a href=\"#{prices['Near Mint']['url']}\" target=\"_blank\" class=\"price-link\">$2,899.99</a>"
      
      # Get the actual rendered HTML by making a request to the page
      get '/'
      expect(last_response.body).to include(expected_html)
    end

    it 'handles errors gracefully' do
      # Test with an invalid card name
      get '/card_info?card='
      expect(last_response.status).to eq(200)
      response_data = JSON.parse(last_response.body)
      expect(response_data).to have_key('error')
    end
  end
end 