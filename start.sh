#!/bin/bash

set -ex  # Exit on any error and print commands as they are executed

echo "=== Starting container ==="
echo "Current directory: $(pwd)"
echo "Environment before setup:"
echo "  DISPLAY=$DISPLAY"
echo "  TESSDATA_PREFIX=$TESSDATA_PREFIX"
echo "  PATH=$PATH"

echo "Checking system information:"
echo "User: $(whoami)"
echo "Groups: $(groups)"
echo "Home directory: $HOME"
echo "Current directory contents:"
ls -la

echo "Checking package manager status:"
if command -v apt-get &> /dev/null; then
    echo "apt-get is available"
    echo "apt-get version:"
    apt-get --version || echo "Could not get apt-get version"
    echo "Checking if we can run apt-get:"
    apt-get -v || echo "apt-get command failed"
else
    echo "apt-get is not available"
fi

echo "Checking for Tesseract:"
if ! command -v tesseract &> /dev/null; then
    echo "Tesseract not found in PATH"
    echo "Searching for tesseract binary:"
    find / -name tesseract 2>/dev/null || echo "No tesseract found in root"
    echo "Checking common locations:"
    ls -l /usr/bin/tesseract 2>/dev/null || echo "Not in /usr/bin"
    ls -l /usr/local/bin/tesseract 2>/dev/null || echo "Not in /usr/local/bin"
    echo "Checking if tesseract packages are installed:"
    dpkg -l | grep tesseract || echo "No tesseract packages found"
    exit 1
fi

echo "Tesseract found at: $(which tesseract)"
echo "Tesseract version:"
tesseract --version || (echo "Tesseract version check failed" && exit 1)

# Verify Tesseract language data
echo "Checking Tesseract language data:"
echo "TESSDATA_PREFIX=$TESSDATA_PREFIX"
ls -l $TESSDATA_PREFIX/eng.traineddata || (echo "Language data not found at $TESSDATA_PREFIX/eng.traineddata" && exit 1)
echo "Language data file exists and is readable"

# Set up environment variables
export DISPLAY=:99
export TESSDATA_PREFIX=/usr/local/share/tessdata

echo "Environment after setup:"
echo "  DISPLAY=$DISPLAY"
echo "  TESSDATA_PREFIX=$TESSDATA_PREFIX"
echo "  PATH=$PATH"

echo "Starting Xvfb..."
Xvfb :99 -screen 0 1024x768x24 &
XVFB_PID=$!
echo "Xvfb started with PID: $XVFB_PID"
echo "Waiting for Xvfb..."
sleep 3

echo "Checking if Xvfb is running..."
ps -p $XVFB_PID > /dev/null || (echo "Xvfb failed to start" && exit 1)

echo "Running scraper script..."
# Run the scraper with error handling and logging
{
    bundle exec ruby scrape_commander_cards.rb 2>&1 | tee scraper.log
    SCRAPER_EXIT=${PIPESTATUS[0]}
} || {
    echo "Scraper failed to start"
    SCRAPER_EXIT=1
}

echo "Scraper exit code: $SCRAPER_EXIT"
echo "Last few lines of scraper log:"
tail -n 50 scraper.log || echo "No scraper log found"

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
    echo "Full scraper log:"
    cat scraper.log || echo "No scraper log available"
    exit 1
fi 