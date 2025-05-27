#!/bin/bash

echo "Starting Xvfb..."
Xvfb :99 -screen 0 1024x768x24 &
echo "Waiting for Xvfb..."
sleep 3

echo "Running scraper script..."
bundle exec ruby scrape_commander_cards.rb

if [ $? -eq 0 ]; then
    echo "Scraper completed successfully"
    echo "Starting server..."
    bundle exec rackup config.ru -o 0.0.0.0 -p 10000
else
    echo "Scraper failed with exit code $?"
    exit 1
fi 