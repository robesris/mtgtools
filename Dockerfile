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
    && rm -rf /var/lib/apt/lists/* && \
    # Verify Tesseract installation and language data
    tesseract --version && \
    echo "Tesseract language data location:" && \
    find /usr/share/tesseract-ocr -name "eng.traineddata" && \
    echo "Setting TESSDATA_PREFIX to:" && \
    echo $(dirname $(find /usr/share/tesseract-ocr -name "eng.traineddata" | head -n 1)) && \
    # Set TESSDATA_PREFIX based on actual installation path
    echo "export TESSDATA_PREFIX=$(dirname $(find /usr/share/tesseract-ocr -name "eng.traineddata" | head -n 1))" >> /etc/profile.d/tesseract.sh && \
    chmod +x /etc/profile.d/tesseract.sh

# Set up display for headless environment
ENV DISPLAY=:99
# Set default TESSDATA_PREFIX (will be overridden by the profile script)
ENV TESSDATA_PREFIX=/usr/share/tesseract-ocr/tessdata

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
CMD . /etc/profile.d/tesseract.sh && Xvfb :99 -screen 0 1024x768x24 -ac & sleep 3 && ./start.sh 