#!/usr/bin/env ruby

require_relative 'scrape_commander_cards'

# Set up environment for OCR
ENV['DISPLAY'] = ':99'  # Use a virtual display
ENV['TESSDATA_PREFIX'] = '/usr/share/tesseract-ocr/4.00/tessdata'  # Set Tesseract data path

# Run the scraper
scraper = CommanderCardScraper.new
scraper.run 