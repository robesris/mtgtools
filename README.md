# Commander Card Scraper

This script scrapes the Commander Game Changers list from the Wizards of the Coast website and creates a single-page view of the cards.

## Prerequisites

Before running the script, you need to install some system dependencies:

### macOS
```bash
brew install tesseract imagemagick
```

### Ubuntu/Debian
```bash
sudo apt-get update
sudo apt-get install tesseract-ocr libmagickwand-dev
```

### Windows
1. Install Tesseract OCR from: https://github.com/UB-Mannheim/tesseract/wiki
2. Install ImageMagick from: https://imagemagick.org/script/download.php

## Installation

1. Install Ruby dependencies:
```bash
bundle install
```

## Usage

Run the script:
```bash
ruby scrape_commander_cards.rb
```

The script will:
1. Download the card list image
2. Process it using OCR to extract card names
3. Generate an HTML file with card images in a grid layout
4. Save everything in the `commander_cards` directory

The output will be available at `commander_cards/commander_cards.html`

## Notes

- The script uses Tesseract OCR to read the card names from the image
- ImageMagick is used to pre-process the image for better OCR results
- Card images are fetched from Gatherer
- If a card image can't be found, a placeholder will be shown 