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

  describe 'Card price lookup flow' do
    let(:card_name) { 'The Tabernacle at Pendrell Vale' }

    it 'completes a full card search and price lookup' do
      # Step 1: Visit the main page
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('Enter a card name')

      # Step 2: Submit a card search
      get "/card_info", card: card_name
      expect(last_response.status).to eq(200)
      
      # Parse the response
      response_data = JSON.parse(last_response.body)
      
      # Verify we got a response with prices
      expect(response_data).to have_key('prices')
      expect(response_data['prices']).to be_a(Hash)
      
      # Verify we have prices for both conditions
      expect(response_data['prices']).to have_key('Near Mint')
      expect(response_data['prices']).to have_key('Lightly Played')
      
      # Verify each price entry has the expected structure
      response_data['prices'].each do |condition, data|
        expect(data).to have_key('price')
        expect(data).to have_key('url')
        expect(data['price']).to match(/^\$\d+\.\d{2}$/)
        expect(data['url']).to match(%r{^https://www\.tcgplayer\.com/product/\d+/.*Condition=#{condition.gsub(' ', '%20')}})
      end

      # Step 3: Verify the rendered HTML on the main page
      get '/'
      expect(last_response.status).to eq(200)
      
      # The page should show the card name and prices
      expect(last_response.body).to include(card_name)
      response_data['prices'].each do |condition, data|
        expect(last_response.body).to include(condition)
        expect(last_response.body).to include(data['price'])
        expect(last_response.body).to include(data['url'])
      end
    end

    it 'handles invalid card names gracefully' do
      # Try with an empty card name
      get "/card_info", card: ''
      expect(last_response.status).to eq(200)
      response_data = JSON.parse(last_response.body)
      expect(response_data).to have_key('error')
      
      # Try with a non-existent card
      get "/card_info", card: 'Not A Real Card 123'
      expect(last_response.status).to eq(200)
      response_data = JSON.parse(last_response.body)
      expect(response_data).to have_key('error')
    end
  end
end 