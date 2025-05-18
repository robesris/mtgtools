require 'nokogiri'
require 'httparty'
require 'csv'
require 'uri'
require 'json'
require 'fileutils'

class GathererScraper
  BASE_URL = 'https://gatherer.wizards.com/Pages/Search/Default.aspx'
  CACHE_FILE = 'card_cache.json'
  CORRECTIONS_FILE = 'card_name_corrections.csv'
  IMAGE_CACHE_DIR = 'card_images'
  
  def initialize(csv_file)
    @csv_file = csv_file
    @not_found_cards = []
    @card_cache = load_cache
    @name_corrections = load_corrections
    FileUtils.mkdir_p(IMAGE_CACHE_DIR)
  end

  def scrape_cards
    cards = []
    CSV.foreach(@csv_file) do |row|
      row.each do |cell|
        next if cell.nil? || cell.strip.empty?
        card_name = cell.strip
        # Handle apostrophes by replacing them with a space for searching
        search_name = card_name.gsub("'", " ")
        corrected_name = @name_corrections[card_name] || search_name
        print "Searching for: #{card_name}"
        print " (corrected to: #{corrected_name})" if corrected_name != card_name
        print "... "
        
        if @card_cache.key?(corrected_name)
          puts "Found in cache!"
          multiverseid = @card_cache[corrected_name]
          image_url = "https://gatherer.wizards.com/Handlers/Image.ashx?multiverseid=#{multiverseid}&type=card"
          local_image_path = File.join(IMAGE_CACHE_DIR, "#{multiverseid}.jpg")
          
          # Download image if not already cached locally
          unless File.exist?(local_image_path)
            begin
              response = HTTParty.get(image_url)
              File.binwrite(local_image_path, response.body)
            rescue => e
              puts "Error downloading image: #{e.message}"
            end
          end
          
          cards << {
            name: card_name,
            image_url: local_image_path,
            found: true
          }
        else
          card_info = search_card(corrected_name)
          if card_info[:found]
            # Extract multiverseid from the image URL and cache it
            if card_info[:image_url] =~ /multiverseid=(\d+)/
              multiverseid = $1
              @card_cache[corrected_name] = multiverseid
              save_cache
              
              # Download and cache the image locally
              local_image_path = File.join(IMAGE_CACHE_DIR, "#{multiverseid}.jpg")
              begin
                response = HTTParty.get(card_info[:image_url])
                File.binwrite(local_image_path, response.body)
                card_info[:image_url] = local_image_path
              rescue => e
                puts "Error downloading image: #{e.message}"
              end
            end
          end
          # Use original name in the output
          card_info[:name] = card_name
          cards << card_info
        end
      end
    end
    generate_html(cards)
    report_not_found
  end

  private

  def load_corrections
    corrections = {}
    if File.exist?(CORRECTIONS_FILE)
      CSV.foreach(CORRECTIONS_FILE, headers: true) do |row|
        corrections[row['incorrect_name']] = row['correct_name']
      end
    end
    corrections
  end

  def load_cache
    if File.exist?(CACHE_FILE)
      JSON.parse(File.read(CACHE_FILE))
    else
      {}
    end
  rescue JSON::ParserError
    puts "Warning: Cache file corrupted, starting with empty cache"
    {}
  end

  def save_cache
    File.write(CACHE_FILE, JSON.pretty_generate(@card_cache))
  end

  def search_card(card_name)
    encoded_name = URI.encode_www_form_component(card_name)
    url = "#{BASE_URL}?name=+#{encoded_name}"
    
    begin
      response = HTTParty.get(url)
      doc = Nokogiri::HTML(response.body)
      
      # Find the first card image in the search results
      card_image = doc.at_css('.cardImage img')
      
      if card_image && card_image['src'] =~ /multiverseid=(\d+)/
        multiverseid = $1
        image_url = "https://gatherer.wizards.com/Handlers/Image.ashx?multiverseid=#{multiverseid}&type=card"
        puts "Found!"
        {
          name: card_name,
          image_url: image_url,
          found: true
        }
      else
        @not_found_cards << card_name
        puts "Not found"
        {
          name: card_name,
          image_url: nil,
          found: false
        }
      end
    rescue => e
      puts "Error: #{e.message}"
      @not_found_cards << card_name
      {
        name: card_name,
        image_url: nil,
        found: false
      }
    end
  end

  def generate_html(cards)
    puts "\nGenerating HTML file..."
    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <title>MTG Card List</title>
        <style>
          body {
            font-family: Arial, sans-serif;
            margin: 20px;
            background-color: #f0f0f0;
          }
          .card-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 20px;
            padding: 20px;
          }
          .card {
            background: white;
            padding: 15px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            text-align: center;
          }
          .card img {
            width: 150%;
            height: auto;
            margin: 0 -25%;
            margin-bottom: 10px;
          }
          .card-name {
            font-weight: bold;
            margin-bottom: 5px;
            font-size: 1.1em;
          }
          .not-found {
            color: #666;
            font-style: italic;
          }
          .corrected-name {
            color: #666;
            font-size: 0.9em;
            font-style: italic;
          }
        </style>
      </head>
      <body>
        <h1>MTG Card List</h1>
        <div class="card-grid">
    HTML

    cards.each do |card|
      corrected_name = @name_corrections[card[:name]]
      html += <<~HTML
        <div class="card">
          #{card[:found] ? "<img src='#{card[:image_url]}' alt='#{card[:name]}'>" : "<div class='not-found'>Image not found</div>"}
          <div class="card-name">#{card[:name]}</div>
          #{corrected_name ? "<div class='corrected-name'>Corrected from: #{corrected_name}</div>" : ""}
        </div>
      HTML
    end

    html += <<~HTML
        </div>
      </body>
      </html>
    HTML

    File.write('mtg_cards.html', html)
    puts "HTML file generated: mtg_cards.html"
  end

  def report_not_found
    if @not_found_cards.any?
      puts "\nCards not found:"
      @not_found_cards.each { |card| puts "- #{card}" }
    end
  end
end

# Run the scraper
scraper = GathererScraper.new('MTG List - Sheet1.csv')
scraper.scrape_cards 