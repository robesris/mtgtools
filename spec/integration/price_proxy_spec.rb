require 'spec_helper'
require 'rack/test'
require 'capybara/rspec'
require 'capybara/dsl'
require 'selenium-webdriver'
require 'httparty'
require 'json'

module ServerCleanup
  def self.kill_server(pid)
    return unless pid
    puts "Attempting to kill server process #{pid}..."
    begin
      # Try SIGTERM first
      Process.kill('TERM', pid)
      # Give it a moment to shut down gracefully
      sleep 1
      # Check if it's still running
      begin
        Process.kill(0, pid)
        # If we get here, process is still running, use SIGKILL
        puts "Server still running, sending SIGKILL..."
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        # Process already gone, which is good
        puts "Server process #{pid} terminated successfully"
      end
    rescue Errno::ESRCH
      puts "Server process #{pid} already terminated"
    rescue => e
      puts "Error killing server process #{pid}: #{e.message}"
    end
  end

  def self.cleanup_port(port)
    puts "Cleaning up port #{port}..."
    begin
      pids = `lsof -i :#{port} | grep LISTEN | awk '{print $2}'`.strip.split("\n")
      pids.each do |pid|
        kill_server(pid.to_i)
      end
      sleep 1
    rescue => e
      puts "Error cleaning up port #{port}: #{e.message}"
    end
  end
end

RSpec.describe 'Price Proxy Integration' do
  include Capybara::DSL
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  # Store server PID globally so at_exit can access it
  $server_pid = nil

  # Ensure server is killed even if tests are aborted
  at_exit do
    puts "\nRunning at_exit cleanup..."
    if $server_pid
      ServerCleanup.kill_server($server_pid)
      $server_pid = nil
    end
    ServerCleanup.cleanup_port(4568)
  end

  before(:all) do
    puts "\nStarting test suite..."
    # Clean up any existing servers first
    ServerCleanup.cleanup_port(4568)

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
    Capybara.server_port = 4568  # Use port 4568 consistently

    # Start the server in a separate process
    puts "Starting server..."
    $server_pid = Process.spawn('ruby price_proxy.rb -p 4568')
    puts "Server started with PID: #{$server_pid}"
    
    # Wait for server to start
    retries = 0
    max_retries = 5
    while retries < max_retries
      begin
        response = HTTParty.get('http://localhost:4568/')
        if response.code == 200
          puts "Server is responding on port 4568"
          break
        end
      rescue => e
        retries += 1
        if retries == max_retries
          ServerCleanup.kill_server($server_pid)
          $server_pid = nil
          raise "Failed to start server after #{max_retries} attempts: #{e.message}"
        end
        puts "Waiting for server to start (attempt #{retries}/#{max_retries})..."
        sleep 1
      end
    end
  end

  after(:all) do
    puts "\nRunning after(:all) cleanup..."
    if $server_pid
      ServerCleanup.kill_server($server_pid)
      $server_pid = nil
    end
    ServerCleanup.cleanup_port(4568)
  end

  it 'fetches card prices from TCGPlayer' do
    # Make a request to the card_info endpoint
    response = HTTParty.get(
      'http://localhost:4568/card_info',
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

    # Expect exact prices for Mox Diamond
    expect(data['prices']['Near Mint']['price']).to eq('$651.00')
    expect(data['prices']['Lightly Played']['price']).to eq('$602.99')
    
    # Verify price format
    data['prices'].each do |condition, price_data|
      expect(price_data).to have_key('price')
      expect(price_data['price']).to match(/^\$\d+\.\d{2}$/)
      expect(price_data).to have_key('url')
      expect(price_data['url']).to include('tcgplayer.com')
    end
  end

  it 'fetches DRANNITH MAGISTRATE prices including shipping' do
    response = HTTParty.get(
      'http://localhost:4568/card_info',
      query: { card: 'DRANNITH MAGISTRATE' }
    )

    expect(response.code).to eq(200)
    data = JSON.parse(response.body)

    expect(data).to have_key('prices')
    expect(data['prices']).to be_a(Hash)

    expect(data['prices']).to have_key('Near Mint')
    expect(data['prices']).to have_key('Lightly Played')

    # Verify Near Mint price details
    nm_data = data['prices']['Near Mint']
    expect(nm_data['price']).to eq('$15.94')
    expect(nm_data['base_price']).to eq('$15.94')
    expect(nm_data['shipping']).to eq('$0.00')
    expect(nm_data['url']).to include('tcgplayer.com')

    # Verify Lightly Played price details
    lp_data = data['prices']['Lightly Played']
    expect(lp_data['price']).to eq('$17.28')
    expect(lp_data['base_price']).to eq('$15.59')
    expect(lp_data['shipping']).to eq('$1.69')
    expect(lp_data['url']).to include('tcgplayer.com')
  end

  xit 'handles invalid card names gracefully' do
    # Make a request with an invalid card name
    response = HTTParty.get(
      'http://localhost:4568/card_info',
      query: { card: 'Not A Real Card Name 123' }
    )

    expect(response.code).to eq(200)
    data = JSON.parse(response.body)
    
    # Verify error response
    expect(data).to have_key('error')
    expect(data['error']).to include('No valid product found')
  end

  # describe 'GET /card_info' do
  #   it 'returns price information for a valid card' do
  #     response = HTTParty.get(
  #       'http://localhost:4568/card_info',
  #       query: { card: 'Sol Ring' }
  #     )

  #     expect(response.code).to eq(200)
  #     data = JSON.parse(response.body)
      
  #     expect(data).to include('prices')
  #     expect(data['prices']).to be_a(Hash)
      
  #     # Check that we have prices for both conditions
  #     expect(data['prices']).to include('Near Mint')
  #     expect(data['prices']).to include('Lightly Played')
      
  #     # Check price format
  #     data['prices'].each do |condition, price_data|
  #       expect(price_data).to include('price')
  #       expect(price_data['price']).to match(/^\$\d+\.\d{2}$/)
  #       expect(price_data).to include('url')
  #       expect(price_data['url']).to start_with('http')
  #     end
  #   end

  #   it 'handles non-existent cards gracefully' do
  #     response = HTTParty.get(
  #       'http://localhost:4568/card_info',
  #       query: { card: 'Not A Real Card Name 12345' }
  #     )

  #     expect(response.code).to eq(200)
  #     data = JSON.parse(response.body)
      
  #     expect(data).to include('error')
  #     expect(data['error']).to be_a(String)
  #   end
  # end
end 