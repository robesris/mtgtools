FROM ruby:3.4.3-slim

# Install system dependencies
RUN apt-get update && \
    apt-get -qq -y install \
    tesseract-ocr \
    tesseract-ocr-eng \
    libtesseract-dev \
    chromium \
    chromium-driver \
    build-essential \
    curl \
    libmagickwand-dev \
    imagemagick \
    xvfb \
    wget \
    && rm -rf /var/lib/apt/lists/* && \
    # Create tessdata directory and download language data
    mkdir -p /usr/local/share/tessdata && \
    wget -q https://github.com/tesseract-ocr/tessdata/raw/main/eng.traineddata -O /usr/local/share/tessdata/eng.traineddata && \
    # Verify Tesseract installation and language data
    tesseract --version && \
    echo "Tesseract language data location:" && \
    ls -l /usr/local/share/tessdata/eng.traineddata

# Set up display for headless environment
ENV DISPLAY=:99
ENV TESSDATA_PREFIX=/usr/local/share/tessdata

# Set working directory
WORKDIR /app

# Copy Gemfile and Gemfile.lock
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies
RUN gem update --system && \
    gem install bundler && \
    bundle config set --local path '/usr/local/bundle' && \
    bundle config set --local without 'development:test' && \
    bundle install --jobs 4 --retry 3

# Copy the application files
COPY . .

# Make start script executable
RUN chmod +x start.sh

# Set environment variables
ENV RACK_ENV=production \
    DEBUG_MODE=false \
    PORT=10000 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_BIN=/usr/local/bundle/bin \
    PATH="/usr/local/bundle/bin:${PATH}"

# Expose the port
EXPOSE 10000

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:10000/ || exit 1

# Start Xvfb and the application
CMD Xvfb :99 -screen 0 1024x768x24 -ac & sleep 3 && ./start.sh 