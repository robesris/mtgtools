#!/bin/bash

set -e  # Exit on any error

echo "=== Starting container ==="
echo "Current directory: $(pwd)"
echo "Environment:"
echo "  DISPLAY=$DISPLAY"
echo "  TESSDATA_PREFIX=$TESSDATA_PREFIX"
echo "  PATH=$PATH"

echo "Checking Tesseract installation..."
which tesseract
tesseract --version

echo "Starting Xvfb..."
Xvfb :99 -screen 0 1024x768x24 &
XVFB_PID=$!
echo "Xvfb started with PID: $XVFB_PID"
echo "Waiting for Xvfb..."
sleep 3

echo "Checking if Xvfb is running..."
ps -p $XVFB_PID > /dev/null || (echo "Xvfb failed to start" && exit 1)

echo "Running scraper script..."
bundle exec ruby scrape_commander_cards.rb
SCRAPER_EXIT=$?

if [ $SCRAPER_EXIT -eq 0 ]; then
    echo "Scraper completed successfully"
    echo "Verifying output..."
    if [ -d "commander_cards/card_images" ]; then
        echo "Card images directory exists"
        IMAGE_COUNT=$(ls commander_cards/card_images/*.jpg 2>/dev/null | wc -l)
        echo "Found $IMAGE_COUNT card images"
    else
        echo "ERROR: Card images directory not created"
        exit 1
    fi
    
    if [ -f "commander_cards/commander_cards.html" ]; then
        echo "HTML file generated successfully"
    else
        echo "ERROR: HTML file not generated"
        exit 1
    fi
    
    echo "Starting server..."
    bundle exec rackup config.ru -o 0.0.0.0 -p 10000
else
    echo "Scraper failed with exit code $SCRAPER_EXIT"
    echo "=== Container startup failed ==="
    exit 1
fi 