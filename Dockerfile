FROM ruby:3.4.3-slim

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    chromium \
    chromium-driver \
    build-essential \
    curl \
    tesseract-ocr \
    libmagickwand-dev \
    imagemagick \
    xvfb \
    && rm -rf /var/lib/apt/lists/*

# Set up display for headless environment
ENV DISPLAY=:99
ENV TESSDATA_PREFIX=/usr/share/tesseract-ocr/4.00/tessdata

# Set working directory
WORKDIR /app

# Copy Gemfile and Gemfile.lock
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies
RUN bundle install --jobs 4 --retry 3

# Copy the application files
COPY . .

# Run the scraper script with Xvfb for headless display
RUN echo "Starting Xvfb..." && \
    Xvfb :99 -screen 0 1024x768x24 & \
    echo "Waiting for Xvfb..." && \
    sleep 3 && \
    echo "Running scraper script..." && \
    bundle exec ruby scrape_commander_cards.rb || (echo "Scraper failed with exit code $?" && exit 1)

# Verify static files are present
RUN ls -la commander_cards/ && \
    test -f commander_cards/commander_cards.html && \
    test -f commander_cards/card_prices.js && \
    test -d commander_cards/card_images && \
    ls -la commander_cards/card_images/ && \
    test -f commander_cards/card_images/479531.jpg

# Set environment variables
ENV RACK_ENV=production \
    DEBUG_MODE=false \
    PORT=10000 \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_DEPLOYMENT=1

# Expose the port
EXPOSE 10000

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:10000/ || exit 1

# Start the application
CMD ["bundle", "exec", "rackup", "config.ru", "-o", "0.0.0.0", "-p", "10000"] 