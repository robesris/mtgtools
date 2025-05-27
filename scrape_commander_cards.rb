#!/usr/bin/env ruby

require 'nokogiri'
require 'httparty'
require 'rtesseract'
require 'rmagick'
require 'down'
require 'fileutils'
require 'uri'
require 'json'

# IMPORTANT: Do NOT change any user-facing text (e.g., 'Click to load prices', 'Near Mint', 'Lightly Played', 'Loading prices', etc).
# All such strings must remain EXACTLY as they are, including capitalization and punctuation, regardless of any code changes.

class CommanderCardScraper
  BASE_URL = 'https://gatherer.wizards.com/Pages/Search/Default.aspx'
  CACHE_FILE = 'commander_card_cache.json'
  PRICE_CACHE_FILE = 'commander_card_prices.json'
  IMAGE_CACHE_DIR = 'commander_card_images'
  
  def initialize
    puts "Initializing CommanderCardScraper..."
    puts "Current directory: #{Dir.pwd}"
    puts "Environment:"
    puts "  DISPLAY=#{ENV['DISPLAY']}"
    puts "  TESSDATA_PREFIX=#{ENV['TESSDATA_PREFIX']}"
    
    @base_url = 'https://magic.wizards.com/en/news/announcements/commander-brackets-beta-update-april-22-2025'
    @image_url = 'https://media.wizards.com/2025/images/daily/g_hItgfH3LjU.jpg'
    @output_dir = 'commander_cards'
    @image_path = File.join(@output_dir, 'commander_cards.jpg')
    @card_cache = load_cache
    @price_cache = load_price_cache
    
    puts "Creating directories..."
    puts "  Output directory: #{@output_dir}"
    puts "  Image path: #{@image_path}"
    FileUtils.mkdir_p(@output_dir)
    FileUtils.mkdir_p(File.join(@output_dir, 'card_images'))
    puts "Directories created successfully"
    
    # Hardcoded color mappings for known cards
    @card_colors = {
      "DRANNITH MAGISTRATE" => ["WHITE"],
      "SERRA'S SANCTUM" => ["COLORLESS"],  # Appears in White section but is actually colorless
      "TEFERI'S PROTECTION" => ["WHITE"],
      "THASSA'S ORACLE" => ["BLUE"],
      "TERGRID, GOD OF FRIGHT" => ["BLACK"],
      "JESKA'S WILL" => ["RED"],
      "GAEA'S CRADLE" => ["COLORLESS"],
      "LION'S EYE DIAMOND" => ["COLORLESS"],
      "MISHRA'S WORKSHOP" => ["COLORLESS"],
      # Multicolored cards with both MULTICOLOR and specific colors
      "YURIKO, THE TIGER'S SHADOW" => ["MULTICOLOR", "BLUE", "BLACK"],
      "AURA SHARDS" => ["MULTICOLOR", "GREEN", "WHITE"],
      "COALITION VICTORY" => ["MULTICOLOR", "GREEN", "WHITE", "RED", "BLUE", "BLACK"],
      "KINNAN, BONDER PRODIGY" => ["MULTICOLOR", "BLUE", "GREEN"],
      "GRAND ARBITER AUGUSTIN IV" => ["MULTICOLOR", "WHITE", "BLUE"],
      "NOTION THIEF" => ["MULTICOLOR", "BLUE", "BLACK"],
      "WINOTA, JOINER OF FORCES" => ["MULTICOLOR", "RED", "WHITE"],
      "BOLAS'S CITADEL" => ["BLACK"],
      "VAMPIRIC TUTOR" => ["BLACK"],
      "CYCLONIC RIFT" => ["BLUE"],
      "CONSECRATED SPHINX" => ["BLUE"],
      "EXPROPRIATE" => ["BLUE"],
      "FORCE OF WILL" => ["BLUE"]
    }
    
    # Skip these garbage OCR results
    @skip_cards = [
      'EOE ROSE SES EE Ee',
      'EOE ROSE SES',
      'ROSE SES',
      'EOE ROSE',
      'SES EE',
      'EE Ee',
      'LANA COMMANDER',
      'BRACKETS',
      'BETA',
      'RED',
      'GREEN',
      'MULTICOLOR'
    ]
    
    # Common card name corrections for OCR issues
    @card_corrections = {
      'SERRAS SANCTUM' => "SERRA'S SANCTUM",
      'SERRA S SANCTUM' => "SERRA'S SANCTUM",
      'TEFERIS PROTECTION' => "TEFERI'S PROTECTION",
      'TEFERI S PROTECTION' => "TEFERI'S PROTECTION",
      'THASSAS ORACLE' => "THASSA'S ORACLE",
      'THASSA S ORACLE' => "THASSA'S ORACLE",
      'TERGRIDS GOD OF FRIGHT' => "TERGRID, GOD OF FRIGHT",
      'JESKAS WILL' => "JESKA'S WILL",
      'JESKA S WILL' => "JESKA'S WILL",
      'GAEAS CRADLE' => "GAEA'S CRADLE",
      'GAEA S CRADLE' => "GAEA'S CRADLE",
      'LIONS EYE DIAMOND' => "LION'S EYE DIAMOND",
      'LION S EYE DIAMOND' => "LION'S EYE DIAMOND",
      'MISHRAS WORKSHOP' => "MISHRA'S WORKSHOP",
      'MISHRA S WORKSHOP' => "MISHRA'S WORKSHOP",
      'YURIKO THE TIGERS SHADOW' => "YURIKO, THE TIGER'S SHADOW",
      'YURIKO, THE TIGERS SHADOW' => "YURIKO, THE TIGER'S SHADOW",
      'BOLASS CITADEL' => "BOLAS'S CITADEL",
      'BOLAS S CITADEL' => "BOLAS'S CITADEL",
      'BOWMASTERS' => "ORCISH BOWMASTERS"  # OCR misread correction for ORCISH BOWMASTERS
    }
    @must_have_cards = [
      "SERRA'S SANCTUM",
      "TEFERI'S PROTECTION",
      "THASSA'S ORACLE",
      "TERGRID, GOD OF FRIGHT",
      "JESKA'S WILL",
      "GAEA'S CRADLE",
      "LION'S EYE DIAMOND",
      "MISHRA'S WORKSHOP",
      "YURIKO, THE TIGER'S SHADOW",
      "BOLAS'S CITADEL"
    ]
  end

  def run
    puts "\n=== Starting Commander Card Scraper ==="
    puts "Downloading image..."
    download_image
    puts "Processing image with OCR..."
    card_names = process_image
    puts "Found #{card_names.length} cards"
    puts "Generating HTML..."
    generate_html(card_names)
    puts "Done! Check #{@output_dir}/commander_cards.html"
    puts "=== Scraper completed ===\n"
  end

  private

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

  def load_price_cache
    if File.exist?(PRICE_CACHE_FILE)
      JSON.parse(File.read(PRICE_CACHE_FILE))
    else
      {}
    end
  rescue JSON::ParserError
    puts "Warning: Price cache file corrupted, starting with empty cache"
    {}
  end

  def save_price_cache
    File.write(PRICE_CACHE_FILE, JSON.pretty_generate(@price_cache))
  end

  def download_image
    if File.exist?(@image_path)
      puts "Using existing image file at #{@image_path}"
      puts "Image file size: #{File.size(@image_path)} bytes"
      return
    end

    puts "Downloading image from #{@image_url}..."
    begin
      tempfile = Down.download(@image_url)
      puts "Downloaded #{tempfile.size} bytes"
      FileUtils.cp(tempfile.path, @image_path)
      tempfile.close!
      puts "Image saved to #{@image_path}"
      puts "Image file size: #{File.size(@image_path)} bytes"
    rescue => e
      puts "Error downloading image: #{e.message}"
      puts "Error backtrace:"
      puts e.backtrace
      raise "Failed to download image: #{e.message}"
    end
  end

  def process_image
    puts "\n=== Processing Image ==="
    # Process image with ImageMagick to improve OCR
    puts "Reading image with ImageMagick..."
    image = Magick::Image.read(@image_path).first
    puts "Source image dimensions: #{image.columns}x#{image.rows} pixels"
    puts "Source image format: #{image.format}"
    
    puts "Processing image for OCR..."
    img = image.quantize(256, Magick::GRAYColorspace)
              .normalize
              .contrast(true)
              .sharpen(0, 1.0)
              .level(0, 65535, 1.1)
              .resize(3.0)
    
    puts "Processed image dimensions: #{img.columns}x#{img.rows} pixels"
    
    processed_path = File.join(@output_dir, 'processed_debug.jpg')
    puts "Saving processed image to #{processed_path}"
    img.write(processed_path)
    puts "Processed image saved, size: #{File.size(processed_path)} bytes"
    
    # Get bounding box data from OCR
    puts "\nRunning OCR..."
    puts "Tesseract version: #{RTesseract.version}"
    ocr = RTesseract.new(processed_path, lang: 'eng')
    boxes = ocr.to_box
    
    # Debug: Show raw OCR box data for first few boxes
    puts "\nRaw OCR box data (first 5 boxes):"
    boxes.first(5).each do |box|
      puts "  Box: #{box.inspect}"
    end
    puts "\n"
    
    # Find the longest card name and estimate its pixel width
    longest_card = 'THE TABERNACLE AT PENDRELL VALE'
    avg_char_width = 40  # Estimate for 3x image
    longest_card_width = longest_card.length * avg_char_width
    column_width = longest_card_width + 100

    # Sort all boxes by x-coordinate and split into exactly 4 columns
    sorted_boxes = boxes.sort_by { |box| box[:x_start].to_i }
    # Find min and max x for all boxes
    min_x = sorted_boxes.map { |b| b[:x_start].to_i }.min
    max_x = sorted_boxes.map { |b| b[:x_start].to_i }.max
    # Calculate column boundaries
    col_boundaries = 4.times.map { |i| min_x + i * ((max_x - min_x) / 4.0) }
    col_boundaries << max_x + column_width  # Add rightmost boundary
    @columns = Array.new(4) { [] }  # Store in instance variable
    # Assign each box to a column based on x_start
    sorted_boxes.each do |box|
      x = box[:x_start].to_i
      col_idx = col_boundaries.each_cons(2).find_index { |left, right| x >= left && x < right }
      @columns[col_idx] << box if col_idx
    end

    puts "Processing 4 columns with known sections:"
    puts "Column 1: WHITE, BLUE"
    puts "Column 2: BLACK, RED"
    puts "Column 3: GREEN, MULTICOLOR"
    puts "Column 4: COLORLESS"

    # Create a mapping of card names to their colors based on the sections
    card_colors = {}
    @columns.each_with_index do |column_boxes, col_idx|
      sorted_col = column_boxes.sort_by { |box| box[:y_start].to_i }
      if col_idx < 3  # First three columns have two sections each
        sec_size = (sorted_col.size / 2.0).ceil
        sections = sorted_col.each_slice(sec_size).to_a
        section_names = case col_idx
          when 0 then ['WHITE', 'BLUE']
          when 1 then ['BLACK', 'RED']
          when 2 then ['GREEN', 'MULTICOLOR']
        end
        sections.each_with_index do |section, sec_idx|
          section.each do |box|
            name = box[:word].strip
            next if name.empty? || @skip_cards.include?(name)
            name = @card_corrections[name] || name
            # Use hardcoded color if available, otherwise use OCR result
            card_colors[name] = @card_colors[name] || [section_names[sec_idx]]
            puts "Card: #{name}, Colors: #{card_colors[name].join(', ')}"
          end
        end
      else  # Last column has one section
        sorted_col.each do |box|
          name = box[:word].strip
          next if name.empty? || @skip_cards.include?(name)
          name = @card_corrections[name] || name
          # Use hardcoded color if available, otherwise use COLORLESS
          card_colors[name] = @card_colors[name] || ['COLORLESS']
          puts "Card: #{name}, Colors: #{card_colors[name].join(', ')}"
        end
      end
    end

    # Process the lines to get actual card names
    all_card_names = []
    @columns.each_with_index do |column_boxes, col_idx|
      sorted_col = column_boxes.sort_by { |box| box[:y_start].to_i }
      if col_idx < 3  # First three columns have two sections each
        sec_size = (sorted_col.size / 2.0).ceil
        sections = sorted_col.each_slice(sec_size).to_a
        section_names = case col_idx
          when 0 then ['WHITE', 'BLUE']
          when 1 then ['BLACK', 'RED']
          when 2 then ['GREEN', 'MULTICOLOR']
        end
        sections.each_with_index do |section_boxes, sec_idx|
          puts "\nColumn #{col_idx + 1} (#{column_boxes.size} boxes):"
          puts "  Section: #{section_names[sec_idx]} (#{section_boxes.size} boxes)"
          # Skip the first box in each section (assumed to be the section title)
          card_boxes = section_boxes.drop(1)
          # Group boxes into lines based on y-coordinates
          lines = group_boxes_into_lines(card_boxes)
          valid_lines = []
          found_first_card = false
          lines.each do |line_boxes|
            # Sort boxes in line by x-coordinate
            sorted_line = line_boxes.sort_by { |box| box[:x_start].to_i }
            # Group all words in the line within the column's boundaries into a single card name
            col_left = col_boundaries[col_idx]
            col_right = col_boundaries[col_idx + 1]
            card_words = sorted_line.select { |box| box[:x_start].to_i >= col_left && box[:x_start].to_i < col_right }
            next if card_words.empty?
            name = merge_line_into_card_name(card_words)
            name = @card_corrections[name] || name
            next if name.strip.empty? || name.strip.length < 3
            next if @skip_cards.include?(name)  # Skip cards in the skip list
            
            # Debug output for specific cards
            if name == "INTUITION" || name == "TERGRID, GOD OF FRIGHT"
              puts "\nDEBUG: Found #{name} in OCR:"
              puts "  Raw boxes: #{card_words.inspect}"
              puts "  Merged name: #{name}"
              puts "  Column: #{col_idx + 1} (#{col_left} to #{col_right})"
              puts "  Line boxes: #{line_boxes.inspect}\n"
            end
            
            # Assign color based on section
            card_colors[name] = @card_colors[name] || [section_names[sec_idx]]
            puts "Card: #{name}, Colors: #{card_colors[name].join(', ')}"
            
            valid_lines << name
            found_first_card = true
          end
          puts "    Cards: " + valid_lines.join(' | ')
          all_card_names.concat(valid_lines)
        end
      else  # Last column has one section
        sections = [sorted_col]
        section_names = ['COLORLESS']
        puts "\nColumn #{col_idx + 1} (#{column_boxes.size} boxes):"
        puts "  Section: #{section_names[0]} (#{sorted_col.size} boxes)"
        # Skip the first box (assumed to be the section title)
        card_boxes = sorted_col.drop(1)
        # Group boxes into lines based on y-coordinates
        lines = group_boxes_into_lines(card_boxes)
        valid_lines = []
        lines.each do |line_boxes|
          # Sort boxes in line by x-coordinate
          sorted_line = line_boxes.sort_by { |box| box[:x_start].to_i }
          # Group all words in the line within the column's boundaries into a single card name
          col_left = col_boundaries[col_idx]
          col_right = col_boundaries[col_idx + 1]
          card_words = sorted_line.select { |box| box[:x_start].to_i >= col_left && box[:x_start].to_i < col_right }
          next if card_words.empty?
          name = merge_line_into_card_name(card_words)
          name = @card_corrections[name] || name
          next if name.strip.empty? || name.strip.length < 3
          next if @skip_cards.include?(name)  # Skip cards in the skip list
          
          # Assign color based on section
          card_colors[name] = @card_colors[name] || ['COLORLESS']
          puts "Card: #{name}, Colors: #{card_colors[name].join(', ')}"
          
          valid_lines << name
        end
        puts "    Cards: " + valid_lines.join(' | ')
        all_card_names.concat(valid_lines)
      end
    end
    
    # Ensure must-have cards are included (unless they're in the skip list)
    @must_have_cards.each do |must|
      all_card_names << must unless all_card_names.include?(must) || @skip_cards.include?(must)
    end
    
    # Store card_colors in instance variable for use in generate_html
    @card_colors = card_colors
    
    all_card_names.uniq
  end

  def group_boxes_into_lines(boxes, y_threshold = 15)
    return [] if boxes.empty?
    
    # Sort boxes by y-coordinate
    sorted = boxes.sort_by { |box| box[:y_start].to_i }
    lines = []
    current_line = [sorted.first]
    
    sorted[1..].each do |box|
      # Calculate the average y-coordinate of the current line
      avg_y = current_line.map { |b| b[:y_start].to_i }.sum / current_line.size.to_f
      # If this box is close to the average y of the current line, add it
      if (box[:y_start].to_i - avg_y).abs <= y_threshold
        current_line << box
      else
        # Start a new line
        lines << current_line
        current_line = [box]
      end
    end
    lines << current_line unless current_line.empty?
    
    lines
  end

  def merge_line_into_card_name(line_boxes)
    # Get the words and clean them up
    words = line_boxes.map do |box|
      word = box[:word].strip
      # Remove any HTML entities and normalize apostrophes
      word.gsub(/&[^;]+;/, '')
          .gsub(/[''`´]/, "'")  # Normalize all types of apostrophes to straight single quote
          .gsub(/[^a-zA-Z0-9\s'\-,\/]/, '') # Keep only letters, numbers, spaces, and common punctuation
          .strip
    end
    
    # Join words with spaces, handling special cases
    name = words.join(' ')
    
    # Clean up common OCR issues
    name.gsub(/\s+/, ' ')           # Normalize spaces
        .gsub(/\s*,\s*/, ', ')     # Fix comma spacing
        .gsub(/\s*'\s*/, "'")      # Fix apostrophe spacing
        .gsub(/\s*-\s*/, '-')      # Fix hyphen spacing
        .gsub(/\s*\/\s*/, '/')     # Fix slash spacing
        .strip
  end

  def get_card_image(card_name)
    # Skip garbage OCR results
    return nil if @skip_cards.include?(card_name)
    
    # Check cache first
    if @card_cache[card_name]
      image_path = File.join(@output_dir, 'card_images', "#{@card_cache[card_name]}.jpg")
      return image_path if File.exist?(image_path)
    end
    
    # Special case: hardcode multiverseid for INTUITION
    if card_name == "INTUITION"
      multiverseid = 397633
      local_image_path = File.join(@output_dir, 'card_images', "#{multiverseid}.jpg")
      unless File.exist?(local_image_path)
        image_url = "https://gatherer.wizards.com/Handlers/Image.ashx?multiverseid=#{multiverseid}&type=card"
        begin
          puts "Downloading image for INTUITION by multiverseid..."
          response = HTTParty.get(image_url)
          File.binwrite(local_image_path, response.body)
        rescue => e
          puts "Error downloading image: #{e.message}"
          return nil
        end
      end
      @card_cache[card_name] = multiverseid
      save_cache
      puts "Found INTUITION by multiverseid!"
      return local_image_path
    end

    # Special case: hardcode multiverseid for TERGRID, GOD OF FRIGHT
    if card_name == "TERGRID, GOD OF FRIGHT"
      multiverseid = 507654
      local_image_path = File.join(@output_dir, 'card_images', "#{multiverseid}.jpg")
      unless File.exist?(local_image_path)
        image_url = "https://gatherer.wizards.com/Handlers/Image.ashx?multiverseid=#{multiverseid}&type=card"
        begin
          puts "Downloading image for TERGRID, GOD OF FRIGHT by multiverseid..."
          response = HTTParty.get(image_url)
          File.binwrite(local_image_path, response.body)
        rescue => e
          puts "Error downloading image: #{e.message}"
          return nil
        end
      end
      @card_cache[card_name] = multiverseid
      save_cache
      puts "Found TERGRID, GOD OF FRIGHT by multiverseid!"
      return local_image_path
    end
    
    # Special case handling for problematic cards
    case card_name
    when "TERGRID, GOD OF FRIGHT"
      # Try comma variants including fullwidth comma
      comma_variants = [
        # Try set name in quotes
        "set:\"Kaldheim\" name:\"Tergrid, God of Fright\"",
        # Try exact case and punctuation
        "Tergrid, God of Fright (Kaldheim)",
        # Try set-first search
        "set=+[%22Kaldheim%22]&name=+[%22Tergrid%22]",
        # Try name-only search (we'll look through all results)
        "name=+[%22Tergrid%22]",
        # Original variants
        card_name,                                    # Original: "TERGRID, GOD OF FRIGHT"
        card_name.gsub(/,\s*/, '，'),                # Fullwidth comma: "TERGRID，GOD OF FRIGHT"
        card_name.gsub(/,\s*/, '， '),               # Fullwidth comma with space: "TERGRID， GOD OF FRIGHT"
        card_name.gsub(/,\s*/, ','),                 # Normal comma no space: "TERGRID,GOD OF FRIGHT"
        card_name.gsub(/,\s*/, ' '),                 # Space instead: "TERGRID GOD OF FRIGHT"
        card_name.gsub(/,\s*/, ''),                  # No comma: "TERGRIDGOD OF FRIGHT",
        # Set name variants
        "Tergrid, God of Fright (Kaldheim)",
        "Tergrid (Kaldheim)"
      ]
      search_variants = comma_variants.uniq
    else
      # Try fullwidth apostrophe first since we know it works
      apostrophe_variants = [
        "＇",  # U+FF07 FULLWIDTH APOSTROPHE (try this first)
        "'",  # U+0027 APOSTROPHE
        "'",  # U+2019 RIGHT SINGLE QUOTATION MARK
        "'",  # U+2018 LEFT SINGLE QUOTATION MARK
        "`",  # U+0060 GRAVE ACCENT
        "´",  # U+00B4 ACUTE ACCENT
        "′",  # U+2032 PRIME
        "‛",  # U+201B SINGLE HIGH-REVERSED-9 QUOTATION MARK
        "ʻ",  # U+02BB MODIFIER LETTER TURNED COMMA
        "ʹ",  # U+02B9 MODIFIER LETTER PRIME
        "ʽ",  # U+02BD MODIFIER LETTER REVERSED COMMA
        "ˈ",  # U+02C8 MODIFIER LETTER VERTICAL LINE
        "ˊ",  # U+02CA MODIFIER LETTER ACUTE ACCENT
        "ˋ",  # U+02CB MODIFIER LETTER GRAVE ACCENT
        "˴",  # U+02F4 MODIFIER LETTER MIDDLE GRAVE ACCENT
        "׳",  # U+05F3 HEBREW PUNCTUATION GERESH
        "՚",  # U+055A ARMENIAN APOSTROPHE
        "ꞌ"   # U+A78C LATIN SMALL LETTER SALTILLO
      ]
      
      # Generate search variants by replacing any apostrophe-like character with each variant
      search_variants = []
      if card_name =~ /[''`´′‛ʻʹʽˈˊˋ˴׳՚ꞌ＇]/
        apostrophe_variants.each do |variant|
          search_variants << card_name.gsub(/[''`´′‛ʻʹʽˈˊˋ˴׳՚ꞌ＇]/, variant)
        end
      elsif card_name =~ /,/
        # For any card with a comma, try comma variants
        comma_variants = [
          card_name,                                    # Original
          card_name.gsub(/,\s*/, '，'),                # Fullwidth comma
          card_name.gsub(/,\s*/, '， '),               # Fullwidth comma with space
          card_name.gsub(/,\s*/, ','),                 # Normal comma no space
          card_name.gsub(/,\s*/, ' '),                 # Space instead
          card_name.gsub(/,\s*/, ''),                  # No comma
        ]
        search_variants = comma_variants.uniq
      else
        search_variants << card_name  # If no apostrophe or comma, just use original name
      end
    end

    search_variants.each do |search_name|
      puts "Trying search: #{search_name}"  # Debug output
      # Handle set-restricted searches differently
      if search_name.start_with?('name=') || search_name.start_with?('set=')
        url = "#{BASE_URL}?#{search_name}"
      elsif search_name.include?('set:') && search_name.include?('name:')
        # Handle set name in quotes format
        set_match = search_name.match(/set:"([^"]+)"/)
        name_match = search_name.match(/name:"([^"]+)"/)
        if set_match && name_match
          set = URI.encode_www_form_component(set_match[1])
          name = URI.encode_www_form_component(name_match[1])
          url = "#{BASE_URL}?set=+[%22#{set}%22]&name=+[%22#{name}%22]"
        else
          url = "#{BASE_URL}?name=+#{URI.encode_www_form_component(search_name)}"
        end
      else
        encoded_name = URI.encode_www_form_component(search_name)
        url = "#{BASE_URL}?name=+#{encoded_name}"
      end
      puts "URL: #{url}"  # Debug output
      response = HTTParty.get(url)
      doc = Nokogiri::HTML(response.body)
      
      # For set-first or name-only searches, look through all results
      if search_name.start_with?('set=') || search_name.start_with?('name=')
        cards = doc.css('.cardItem')
        if cards.any?
          # Normalize the target name for comparison
          normalized_target = card_name.downcase.gsub(/[''`´′‛ʻʹʽˈˊˋ˴׳՚ꞌ＇]/, "'").gsub(/\s+/, ' ').strip
          found = false
          cards.each do |card|
            card_title = card.at_css('.cardTitle a')&.text&.strip || ''
            normalized_card = card_title.downcase.gsub(/[''`´′‛ʻʹʽˈˊˋ˴׳՚ꞌ＇]/, "'").gsub(/\s+/, ' ').strip
            # For INTUITION, look for exact match (not Artificer's Intuition)
            if card_name == "INTUITION"
              next unless normalized_card == "intuition"
            # For TERGRID, look for partial match
            elsif card_name == "TERGRID, GOD OF FRIGHT"
              next unless normalized_card.include?("tergrid") && normalized_card.include?("god of fright")
            # For other cards, look for exact match
            else
              next unless normalized_card == normalized_target
            end
            card_image = card.at_css('.cardImage img')
            if card_image && card_image['src'] =~ /multiverseid=(\d+)/
              multiverseid = $1
              @card_cache[card_name] = multiverseid  # Store with original name
              save_cache
              image_url = "https://gatherer.wizards.com/Handlers/Image.ashx?multiverseid=#{multiverseid}&type=card"
              local_image_path = File.join(@output_dir, 'card_images', "#{multiverseid}.jpg")
              unless File.exist?(local_image_path)
                begin
                  puts "Downloading image for #{card_name}..."
                  response = HTTParty.get(image_url)
                  File.binwrite(local_image_path, response.body)
                rescue => e
                  puts "Error downloading image: #{e.message}"
                  return nil
                end
              end
              puts "Found #{card_name}! (via search: #{search_name}, matched: #{card_title})"
              return local_image_path
            end
            found = true
            break
          end
          puts "Not found: #{search_name} (no matching card in results)" unless found
        else
          puts "Not found: #{search_name} (no results)"
        end
      else
        # Original exact match logic for other searches
        card_image = doc.at_css('.cardImage img')
        if card_image && card_image['src'] =~ /multiverseid=(\d+)/
          multiverseid = $1
          @card_cache[card_name] = multiverseid  # Store with original name
          save_cache
          image_url = "https://gatherer.wizards.com/Handlers/Image.ashx?multiverseid=#{multiverseid}&type=card"
          local_image_path = File.join(@output_dir, 'card_images', "#{multiverseid}.jpg")
          unless File.exist?(local_image_path)
            begin
              puts "Downloading image for #{card_name}..."
              response = HTTParty.get(image_url)
              File.binwrite(local_image_path, response.body)
            rescue => e
              puts "Error downloading image: #{e.message}"
              return nil
            end
          end
          puts "Found #{card_name}! (via search: #{search_name})"
          return local_image_path
        else
          # Fallback: check for 'Object moved to' redirect with multiverseid
          if response.body =~ /Object moved to <a href="\/Pages\/Card\/Details\.aspx\?multiverseid=(\d+)">here<\/a>/
            multiverseid = $1
            local_image_path = File.join(@output_dir, 'card_images', "#{multiverseid}.jpg")
            unless File.exist?(local_image_path)
              image_url = "https://gatherer.wizards.com/Handlers/Image.ashx?multiverseid=#{multiverseid}&type=card"
              begin
                puts "Downloading image for #{card_name} by redirect multiverseid..."
                img_response = HTTParty.get(image_url)
                File.binwrite(local_image_path, img_response.body)
              rescue => e
                puts "Error downloading image: #{e.message}"
                return nil
              end
            end
            @card_cache[card_name] = multiverseid
            save_cache
            puts "Found #{card_name} by redirect multiverseid!"
            return local_image_path
          end
          puts "Not found: #{search_name} (no exact match)"
        end
      end
    end
    # Fallback: try bracketed search if all else fails
    bracketed_name = "[#{card_name}]"
    encoded_bracketed = URI.encode_www_form_component(bracketed_name)
    url = "#{BASE_URL}?name=+#{encoded_bracketed}"
    puts "Trying bracketed search: #{bracketed_name}"
    puts "URL: #{url}"
    response = HTTParty.get(url)
    doc = Nokogiri::HTML(response.body)
    card_image = doc.at_css('.cardImage img')
    if card_image && card_image['src'] =~ /multiverseid=(\d+)/
      multiverseid = $1
      @card_cache[card_name] = multiverseid
      save_cache
      image_url = "https://gatherer.wizards.com/Handlers/Image.ashx?multiverseid=#{multiverseid}&type=card"
      local_image_path = File.join(@output_dir, 'card_images', "#{multiverseid}.jpg")
      unless File.exist?(local_image_path)
        begin
          puts "Downloading image for #{card_name} (bracketed search)..."
          response = HTTParty.get(image_url)
          File.binwrite(local_image_path, response.body)
        rescue => e
          puts "Error downloading image: #{e.message}"
          return nil
        end
      end
      puts "Found #{card_name} (bracketed search)!"
      return local_image_path
    end
    puts "Not found: #{card_name} (all variants and bracketed search tried)"
    nil
  end

  def get_card_prices(card_name)
    # Skip if we have recent cached prices (less than 24 hours old)
    if @price_cache[card_name] && @price_cache[card_name]['timestamp'] > (Time.now - 86400).to_i
      return @price_cache[card_name]['prices']
    end

    # Convert card name to TCGPlayer format (lowercase, spaces to hyphens)
    tcg_name = card_name.downcase.gsub(/[^a-z0-9\s-]/, '').gsub(/\s+/, '-')
    url = "https://www.tcgplayer.com/search/magic/product?q=#{URI.encode_www_form_component(tcg_name)}"
    
    begin
      response = HTTParty.get(url, {
        headers: {
          'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
        }
      })
      
      doc = Nokogiri::HTML(response.body)
      
      # Find the first product card that matches our search
      product_card = doc.at_css('.product-card')
      return nil unless product_card
      
      # Get the product URL
      product_url = product_card.at_css('a')['href']
      return nil unless product_url
      
      # Get the product page to find prices
      product_response = HTTParty.get(product_url, {
        headers: {
          'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
        }
      })
      
      product_doc = Nokogiri::HTML(product_response.body)
      
      # Find price rows for LP and NM
      prices = {}
      product_doc.css('.price-point').each do |price_point|
        condition = price_point.at_css('.condition')&.text&.strip&.downcase
        next unless ['lightly played', 'near mint'].include?(condition)
        
        price = price_point.at_css('.price')&.text&.strip
        shipping = price_point.at_css('.shipping')&.text&.strip
        total = if shipping && shipping =~ /(\$[\d.]+)/
          price.to_f + $1.gsub('$', '').to_f
        else
          price.to_f
        end
        
        prices[condition] = {
          'price' => price,
          'shipping' => shipping,
          'total' => sprintf('$%.2f', total),
          'url' => product_url
        }
      end
      
      # Cache the prices
      @price_cache[card_name] = {
        'timestamp' => Time.now.to_i,
        'prices' => prices
      }
      save_price_cache
      
      prices
    rescue => e
      puts "Error getting prices for #{card_name}: #{e.message}"
      nil
    end
  end

  def generate_html(card_names)
    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <title>Commander Game Changers List</title>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 20px;
            background: #f5f5f5;
          }
          .container {
            max-width: 1600px;
            margin: 0 auto;
            padding: 0 20px;
            display: flex;
            gap: 20px;
            position: relative;
            width: 100%;
            box-sizing: border-box;
          }
          .color-filter-tray {
            width: 200px;
            min-width: 200px;
            max-width: 200px;
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            padding: 15px;
            position: sticky;
            top: 20px;
            height: fit-content;
            transition: width 0.3s ease, min-width 0.3s ease, max-width 0.3s ease, padding 0.3s ease;
            z-index: 1;
            flex-shrink: 0;
          }
          .color-filter-tray.collapsed {
            width: 30px;
            min-width: 30px;
            max-width: 30px;
            padding: 15px 5px;
          }
          .color-filter-tray .filter-content {
            opacity: 1;
            visibility: visible;
            transition: opacity 0.2s ease, visibility 0.2s, width 0.3s ease;
            width: 100%;
            padding: 5px 0;
            display: flex;
            flex-direction: column;
            gap: 15px;
            min-width: 0;
          }
          .color-filter-tray.collapsed .filter-content {
            opacity: 0;
            visibility: hidden;
            width: 0;
            min-width: 0;
            padding: 0;
          }
          .color-filter-tray .toggle-button {
            position: absolute;
            right: -30px;
            top: 50%;
            transform: translateY(-50%);
            background: white;
            border: none;
            border-radius: 0 4px 4px 0;
            padding: 10px;
            cursor: pointer;
            box-shadow: 2px 0 4px rgba(0,0,0,0.1);
            display: flex;
            align-items: center;
            justify-content: center;
            z-index: 2;
            width: 30px;
            height: 30px;
            transition: all 0.3s ease;
            font-size: 0; /* Hide any text content */
          }
          .color-filter-tray.collapsed .toggle-button {
            transform: translateY(-50%);
            right: -30px;
            border-radius: 0 4px 4px 0;
            box-shadow: 2px 0 4px rgba(0,0,0,0.1);
            background: white;
            border: none;
          }
          .color-filter-tray .toggle-button::before {
            content: "▶";
            font-size: 12px;
            line-height: 1;
            transition: transform 0.3s ease;
          }
          .color-filter-tray.collapsed .toggle-button::before {
            transform: rotate(180deg);
          }
          .color-filter-tray label {
            position: relative;
            display: block;
            cursor: pointer;
            width: 100%;
            height: 32px;  /* Fixed height */
            margin: 0;  /* Remove margin */
            padding: 0;  /* Remove padding */
            border-radius: 4px;
            transition: background-color 0.2s;
            box-sizing: border-box;
            overflow: hidden;  /* Prevent content from affecting layout */
          }
          .color-filter-tray label:last-child {
            margin: 0;
          }
          .color-filter-tray label:hover {
            background-color: #f5f5f5;
          }
          .color-filter-tray label input[type="checkbox"] {
            position: absolute;
            left: 5px;
            top: 50%;
            transform: translateY(-50%);
            margin: 0;
            width: 16px;
            height: 16px;
            z-index: 2;
            pointer-events: auto;
          }
          .color-filter-tray label span:not(.only-icon) {
            position: absolute;
            left: 29px;  /* checkbox width + padding */
            right: 29px;  /* eye icon width + padding */
            top: 50%;
            transform: translateY(-50%);
            text-align: left;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
            z-index: 1;
            pointer-events: none;  /* Prevent text from interfering with clicks */
          }
          .color-filter-tray .only-icon {
            position: absolute;
            right: 5px;
            top: 50%;
            transform: translateY(-50%);
            cursor: pointer;
            opacity: 0.7;
            transition: opacity 0.2s;
            width: 20px;
            height: 20px;  /* Fixed height */
            line-height: 20px;  /* Center the eye icon vertically */
            text-align: center;
            z-index: 2;
            pointer-events: auto;
            user-select: none;  /* Prevent text selection */
            -webkit-user-select: none;
          }
          .color-filter-tray .only-icon:hover {
            opacity: 1;
          }
          .card-grid {
            flex: 1;
            display: grid;
            grid-template-columns: repeat(4, minmax(0, 1fr));
            gap: 20px;
            margin-top: 20px;
            margin-left: 20px; /* Increased from 10px to 20px to prevent overlap */
            align-items: start;
            width: 100%;
            box-sizing: border-box;
            min-width: 0;
          }
          .card {
            background: white;
            padding: 15px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            text-align: center;
            display: flex;
            flex-direction: column;
            align-items: center;
            cursor: pointer;
            transition: transform 0.2s, opacity 0.3s, visibility 0.3s;
            width: 100%;
            box-sizing: border-box;
            min-width: 0;
            opacity: 1;
            visibility: visible;
          }
          .card.hidden-by-color {
            opacity: 0;
            visibility: hidden;
            pointer-events: none;
            position: absolute;
          }
          .card.hidden-by-all {
            display: none;
          }
          .card:hover {
            transform: translateY(-5px);
          }
          .card-image-container {
            width: 100%;
            position: relative;
            padding-top: 139.7%; /* Magic card aspect ratio (3.5:2.5) */
          }
          .card img {
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            object-fit: contain;
          }
          .card-name {
            font-weight: bold;
            color: #333;
            font-size: 1.1em;
            margin: 10px 0;
            padding: 0 5px;
            width: 100%;
            box-sizing: border-box;
          }
          .price-info {
            margin-top: 10px;
            font-size: 0.9em;
            color: #666;
            width: 100%;
            text-align: left;
            padding: 0 5px;
          }
          .price-info a {
            color: #0066cc;
            text-decoration: none;
          }
          .price-info a:hover {
            text-decoration: underline;
          }
          /* Make timestamp styling more specific and forceful */
          .price-info .price-timestamp {
            display: block;
            font-size: 0.65em !important;
            margin-top: 4px;
            font-style: italic;
            line-height: 1.2;
            color: #666;
          }
          .price-info .price-timestamp.recent {
            color: #2ecc71 !important;
          }
          .price-info .price-timestamp.old {
            color: #e67e22 !important;
          }
          .price-info .price-timestamp.very-old {
            color: #e74c3c !important;
          }
          .loading {
            color: #999;
            font-style: italic;
          }
          h1 {
            color: #2c3e50;
            text-align: center;
            margin-bottom: 30px;
            padding: 0 20px;
          }
          .source {
            text-align: center;
            margin-top: 30px;
            color: #666;
            font-size: 0.9em;
            padding: 0 20px;
          }
          .not-found {
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            color: #666;
            font-style: italic;
            padding: 15px;
            background: #f8f8f8;
            border-radius: 4px;
            width: 80%;
            text-align: center;
          }
          @media (max-width: 1400px) {
            .card-grid {
              grid-template-columns: repeat(3, minmax(0, 1fr));  /* 3 columns on medium screens */
            }
          }
          @media (max-width: 1000px) {
            .card-grid {
              grid-template-columns: repeat(2, minmax(0, 1fr));  /* 2 columns on smaller screens */
            }
          }
          @media (max-width: 600px) {
            .card-grid {
              grid-template-columns: repeat(1, minmax(0, 1fr));  /* 1 column on mobile */
            }
            .card {
              padding: 10px;
            }
            .card-name {
              font-size: 1em;
            }
          }
        </style>
        <script src="card_prices.js"></script>
      </head>
      <body>
        <div class="container">
          <div class="color-filter-tray">
            <button class="toggle-button" title="Toggle filter tray"></button>
            <div class="filter-content">
              <label><input type="checkbox" data-color="all" checked /><span>ALL</span></label>
              <label><input type="checkbox" data-color="White" checked /><span>White</span><span class="only-icon" data-color="White" title="Show only White cards">👁️</span></label>
              <label><input type="checkbox" data-color="Blue" checked /><span>Blue</span><span class="only-icon" data-color="Blue" title="Show only Blue cards">👁️</span></label>
              <label><input type="checkbox" data-color="Black" checked /><span>Black</span><span class="only-icon" data-color="Black" title="Show only Black cards">👁️</span></label>
              <label><input type="checkbox" data-color="Red" checked /><span>Red</span><span class="only-icon" data-color="Red" title="Show only Red cards">👁️</span></label>
              <label><input type="checkbox" data-color="Green" checked /><span>Green</span><span class="only-icon" data-color="Green" title="Show only Green cards">👁️</span></label>
              <label><input type="checkbox" data-color="Multicolor" checked /><span>Multicolor</span><span class="only-icon" data-color="Multicolor" title="Show only Multicolor cards">👁️</span></label>
              <label><input type="checkbox" data-color="Colorless" checked /><span>Colorless</span><span class="only-icon" data-color="Colorless" title="Show only Colorless cards">👁️</span></label>
            </div>
          </div>
          <div>
            <h1>Commander Game Changers List</h1>
            <div style="text-align: center; margin-bottom: 20px;">
              <button id="fetch-all-prices" style="padding: 10px 20px; font-size: 16px; background-color: #4CAF50; color: white; border: none; border-radius: 4px; cursor: pointer; transition: background-color 0.2s;">Fetch All Prices</button>
              <div id="fetch-status" style="margin-top: 10px; font-style: italic; color: #666;"></div>
            </div>
            <div class="card-grid">
    HTML

    # Use the card_colors mapping we created during OCR
    card_names.each do |name|
      image_path = get_card_image(name)
      prices = @price_cache[name]&.dig('prices')
      
      price_html = if prices
        html = []
        if prices['near mint']
          nm = prices['near mint']
          html << "Near Mint: <a href=\"#{nm['url']}\" target=\"_blank\">$${nm['total']}</a>"
        end
        if prices['lightly played']
          lp = prices['lightly played']
          html << "Lightly Played: <a href=\"#{lp['url']}\" target=\"_blank\">$${lp['total']}</a>"
        end
        html.join(' | ') || 'No prices found'
      else
        'Click to load prices'
      end
      
      # Get the colors for this card from our mapping
      colors = @card_colors[name] || []
      data_colors = colors.join(',').downcase
      
      if image_path
        image_filename = File.basename(image_path)
        relative_path = "card_images/#{image_filename}"
        html += <<~HTML
          <div class="card" data-colors="#{data_colors}">
            <div class="card-name">#{name}</div>
            <div class="card-image-container">
              <img src="#{relative_path}" alt="#{name}">
            </div>
            <div class="price-info">#{price_html}</div>
          </div>
        HTML
      else
        html += <<~HTML
          <div class="card" data-colors="#{data_colors}">
            <div class="card-name">#{name}</div>
            <div class="card-image-container">
              <div class="not-found">Image not found</div>
            </div>
            <div class="price-info">#{price_html}</div>
          </div>
        HTML
      end
    end

    html += <<~HTML
            </div>
            <div class="source">
              Source: <a href="#{@base_url}">Commander Brackets Beta Update - April 22, 2025</a>
            </div>
          </div>
        </div>
        <script>
          document.addEventListener('DOMContentLoaded', function() {
            const tray = document.querySelector('.color-filter-tray');
            const toggleButton = document.querySelector('.toggle-button');
            const allCheckbox = document.querySelector('input[data-color="all"]');
            const colorCheckboxes = document.querySelectorAll('input[data-color]:not([data-color="all"])');
            const onlyIcons = document.querySelectorAll('.only-icon');
            const cards = document.querySelectorAll('.card');
            const fetchAllButton = document.getElementById('fetch-all-prices');
            const fetchStatus = document.getElementById('fetch-status');
            
            // Function to animate ellipsis
            function animateEllipsis(element, text) {
              let dots = 0;
              const maxDots = 3;
              const interval = setInterval(() => {
                dots = (dots + 1) % (maxDots + 1);
                element.innerHTML = `${text}${'.'.repeat(dots)}`;
              }, 500);
              return interval;
            }

            // Function to fetch prices for a single card
            async function fetchCardPrices(cardElement) {
              const cardName = cardElement.querySelector('.card-name').textContent;
              const priceInfo = cardElement.querySelector('.price-info');
              
              try {
                priceInfo.innerHTML = '<span class="loading">Fetching prices</span>';
                const ellipsisInterval = animateEllipsis(priceInfo.querySelector('.loading'), 'Fetching prices');
                
                const response = await fetch(`http://localhost:4567/card_info?card=${encodeURIComponent(cardName)}`);
                clearInterval(ellipsisInterval);
                
                if (!response.ok) {
                  throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                
                if (data && data.prices) {
                  // Cache the prices immediately after successful fetch
                  await fetch('http://localhost:4567/cache_prices', {
                    method: 'POST',
                    headers: {
                      'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                      card: cardName,
                      prices: data.prices,
                      timestamp: data.timestamp || Math.floor(Date.now() / 1000)
                    })
                  });

                  let html = [];
                  if (data.prices['Near Mint']) {
                    const nm = data.prices['Near Mint'];
                    html.push(`Near Mint: <a href="${data.tcgplayer_url}" target="_blank">$${parseFloat(nm).toFixed(2)}</a>`);
                  }
                  if (data.prices['Lightly Played']) {
                    const lp = data.prices['Lightly Played'];
                    html.push(`Lightly Played: <a href="${data.tcgplayer_url}" target="_blank">$${parseFloat(lp).toFixed(2)}</a>`);
                  }
                  if (data.timestamp) {
                    const timestamp = new Date(data.timestamp * 1000);
                    const now = new Date();
                    const hoursAgo = Math.floor((now - timestamp) / (1000 * 60 * 60));
                    let timestampClass = 'recent';
                    if (hoursAgo > 24) {
                      timestampClass = hoursAgo > 48 ? 'very-old' : 'old';
                    }
                    html.push(`<span class="price-timestamp ${timestampClass}">Updated ${hoursAgo} hours ago</span>`);
                  }
                  priceInfo.innerHTML = html.join(' | ') || 'No prices found';
                } else {
                  priceInfo.innerHTML = 'No prices found';
                }
              } catch (error) {
                console.error('Error fetching prices for', cardName, ':', error);
                priceInfo.innerHTML = 'Click to load prices';
              }
            }
            
            // Function to fetch all prices
            async function fetchAllPrices() {
              if (fetchAllButton.disabled) return; // Prevent multiple clicks
              
              fetchAllButton.disabled = true;
              fetchAllButton.style.backgroundColor = '#999';
              fetchStatus.textContent = 'Fetching prices';
              let ellipsisInterval = animateEllipsis(fetchStatus, 'Fetching prices');
              
              const cardElements = Array.from(cards);
              let completed = 0;
              let failed = 0;
              
              // Process cards one at a time
              for (const card of cardElements) {
                try {
                  await fetchCardPrices(card);
                  completed++;
                } catch (error) {
                  console.error('Error fetching prices for card:', error);
                  failed++;
                }
                clearInterval(ellipsisInterval);
                fetchStatus.textContent = `Fetched ${completed} cards${failed > 0 ? `, ${failed} failed` : ''}...`;
                ellipsisInterval = animateEllipsis(fetchStatus, `Fetched ${completed} cards${failed > 0 ? `, ${failed} failed` : ''}`);
                // Add a small delay between cards to avoid rate limiting
                await new Promise(resolve => setTimeout(resolve, 1000));
              }
              clearInterval(ellipsisInterval);
              fetchStatus.textContent = `Completed: ${completed} cards fetched${failed > 0 ? `, ${failed} failed` : ''}`;
              fetchAllButton.disabled = false;
            }
            
            // Add click handler for the fetch all button
            fetchAllButton.addEventListener('click', fetchAllPrices);
            
            // Function to update card visibility based on selected colors
            function updateCardVisibility() {
              // First, remove all visibility classes
              cards.forEach(card => {
                card.classList.remove('hidden-by-color');
                card.classList.remove('hidden-by-all');
              });
              
              // If ALL is checked, we're done - all cards are visible
              if (allCheckbox.checked) {
                return;
              }
              
              // Otherwise, apply color filtering
              const selectedColors = Array.from(colorCheckboxes)
                .filter(cb => cb.checked)
                .map(cb => cb.dataset.color.toLowerCase());
              
              cards.forEach(card => {
                const cardColors = card.dataset.colors.split(',');
                // Special handling for Multicolor cards
                const shouldShow = selectedColors.some(color => {
                  if (color === 'multicolor') {
                    return cardColors.includes('multicolor');
                  } else {
                    return cardColors.includes(color);
                  }
                });
                if (!shouldShow) {
                  card.classList.add('hidden-by-color');
                }
              });
            }
            
            // Handle ALL checkbox
            allCheckbox.addEventListener('change', function() {
              // When ALL is checked, remove all visibility classes
              if (this.checked) {
                cards.forEach(card => {
                  card.classList.remove('hidden-by-color');
                  card.classList.remove('hidden-by-all');
                });
              } else {
                // When ALL is unchecked, update based on color checkboxes
                updateCardVisibility();
              }
            });
            
            // Handle individual color checkboxes
            colorCheckboxes.forEach(checkbox => {
              checkbox.addEventListener('change', function() {
                // When any color checkbox changes, uncheck ALL
                allCheckbox.checked = false;
                // Update visibility based on color checkboxes
                updateCardVisibility();
              });
            });
            
            // Handle "only" icons
            onlyIcons.forEach(icon => {
              icon.addEventListener('click', function(e) {
                e.stopPropagation(); // Prevent label click
                const color = this.dataset.color.toLowerCase();
                
                // Uncheck ALL
                allCheckbox.checked = false;
                
                // Uncheck all colors except the clicked one
                colorCheckboxes.forEach(cb => {
                  // For Multicolor cards, we need to check if the card has "multicolor" in its colors
                  if (color === 'multicolor') {
                    cb.checked = cb.dataset.color.toLowerCase() === color;
                  } else {
                    cb.checked = cb.dataset.color.toLowerCase() === color;
                  }
                });
                
                // Update visibility
                updateCardVisibility();
              });
            });
            
            // Toggle tray
            toggleButton.addEventListener('click', function() {
              tray.classList.toggle('collapsed');
            });
            
            // Initial visibility update
            updateCardVisibility();
          });
        </script>
      </body>
      </html>
    HTML

    File.write(File.join(@output_dir, 'commander_cards.html'), html)
  end

  def generate_filter_tray_html
    colors = ['White', 'Blue', 'Black', 'Red', 'Green', 'Multicolor', 'Colorless']
    html = <<~HTML
      <div class="filter-tray-container">
        <div class="filter-tray">
          <div class="filter-tray-content">
            #{colors.map { |color| generate_filter_label(color) }.join("\n")}
          </div>
        </div>
      </div>
    HTML
    html
  end

  def generate_filter_label(color)
    color_id = color.downcase
    <<~HTML
      <div class="filter-label-wrapper" data-color="#{color_id}">
        <input type="checkbox" id="filter-#{color_id}" class="filter-checkbox" data-color="#{color_id}">
        <label for="filter-#{color_id}" class="filter-label">
          <span class="filter-text filter-text-#{color_id}">#{color}</span>
          <span class="only-icon" data-color="#{color_id}" title="Show only #{color} cards">👁️</span>
        </label>
      </div>
    HTML
  end

  def generate_css
    <<~CSS
      /* Reset and base styles */
      * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
      }

      body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        line-height: 1.5;
        color: #333;
        background: #f5f5f5;
        padding: 20px;
      }

      /* Filter tray container */
      .filter-tray-container {
        position: sticky;
        top: 0;
        z-index: 100;
        background: #f5f5f5;
        padding: 10px 0;
        margin-bottom: 20px;
        border-bottom: 1px solid #ddd;
      }

      .filter-tray {
        max-width: 1600px;
        margin: 0 auto;
        padding: 0 20px;
      }

      .filter-tray-content {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        align-items: center;
      }

      /* Filter label wrapper */
      .filter-label-wrapper {
        position: relative;
        height: 32px;
        min-width: 120px;
        flex: 0 1 auto;
      }

      /* Filter checkbox */
      .filter-checkbox {
        position: absolute;
        left: 0;
        top: 50%;
        transform: translateY(-50%);
        width: 16px;
        height: 16px;
        margin: 0;
        z-index: 2;
        cursor: pointer;
      }

      /* Filter label */
      .filter-label {
        position: relative;
        display: block;
        height: 100%;
        padding: 0 32px 0 24px;
        background: #fff;
        border: 1px solid #ddd;
        border-radius: 4px;
        cursor: pointer;
        user-select: none;
      }

      .filter-label:hover {
        background: #f8f8f8;
        border-color: #ccc;
      }

      /* Filter text */
      .filter-text {
        display: block;
        height: 100%;
        line-height: 32px;
        font-size: 14px;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
        pointer-events: none;
      }

      /* Colored filter text classes (restored) */
      .filter-text-white {
         background: #fff; color: #333; border: 1px solid #ddd; border-radius: 4px; padding: 2px 8px; box-shadow: 0 1px 2px rgba(0,0,0,0.03);
      }
      .filter-text-blue {
         background: #0070BA; color: #fff; border-radius: 4px; padding: 2px 8px;
      }
      .filter-text-black {
         background: #150B00; color: #fff; border-radius: 4px; padding: 2px 8px;
      }
      .filter-text-red {
         background: #D3202A; color: #fff; border-radius: 4px; padding: 2px 8px;
      }
      .filter-text-green {
         background: #00733E; color: #fff; border-radius: 4px; padding: 2px 8px;
      }
      .filter-text-multicolor {
         background: linear-gradient(90deg, #0070BA 0%, #D3202A 50%, #00733E 100%); color: #fff; border-radius: 4px; padding: 2px 8px;
      }
      .filter-text-colorless {
         background: #e0e0e0; color: #333; border-radius: 4px; padding: 2px 8px;
      }

      /* Only icon */
      .only-icon {
        position: absolute;
        right: 8px;
        top: 50%;
        transform: translateY(-50%);
        width: 20px;
        height: 20px;
        display: flex;
        align-items: center;
        justify-content: center;
        font-size: 14px;
        color: #666;
        cursor: pointer;
        z-index: 2;
        transition: color 0.2s;
        user-select: none;
      }

      .only-icon:hover {
        color: #333;
      }

      /* Card grid */
      .card-grid {
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
        gap: 20px;
        max-width: 1600px;
        margin: 0 auto;
        padding: 0 20px;
      }

      @media (min-width: 1400px) {
        .card-grid {
          grid-template-columns: repeat(4, 1fr);
        }
      }

      @media (min-width: 1000px) and (max-width: 1399px) {
        .card-grid {
          grid-template-columns: repeat(3, 1fr);
        }
      }

      @media (min-width: 600px) and (max-width: 999px) {
        .card-grid {
          grid-template-columns: repeat(2, 1fr);
        }
      }

      @media (max-width: 599px) {
        .card-grid {
          grid-template-columns: 1fr;
        }
      }

      /* Card styles */
      .card {
        position: relative;
        background: #fff;
        border: 1px solid #ddd;
        border-radius: 8px;
        padding: 15px;
        transition: transform 0.2s, box-shadow 0.2s, opacity 0.2s, visibility 0.2s;
        min-width: 0;
        cursor: pointer;
      }

      .card:hover {
        transform: translateY(-2px);
        box-shadow: 0 4px 8px rgba(0,0,0, 0.1);
      }

      .card.hidden-by-color {
        opacity: 0; visibility: hidden; pointer-events: none; position: absolute;
      }

      .card.hidden-by-all {
        display: none;
      }

      /* Rest of your existing card styles... */
      #{generate_card_css}
    CSS
  end
end

# Add debugging output when script is run directly
if __FILE__ == $PROGRAM_NAME
  puts "=== Starting scraper script ==="
  puts "Ruby version: #{RUBY_VERSION}"
  puts "Current directory: #{Dir.pwd}"
  puts "Environment:"
  puts "  DISPLAY=#{ENV['DISPLAY']}"
  puts "  TESSDATA_PREFIX=#{ENV['TESSDATA_PREFIX']}"
  puts "  PATH=#{ENV['PATH']}"
  puts "Checking Tesseract installation:"
  system('which tesseract')
  system('tesseract --version')
  puts "=== Starting scraper ==="
  
  scraper = CommanderCardScraper.new
  scraper.run
end 