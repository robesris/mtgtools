FROM ruby:3.4.3-slim

# Install system dependencies
RUN apt-get update && \
    apt-get -qq -y install tesseract-ocr && \
    apt-get -qq -y install libtesseract-dev && \
    apt-get -qq -y install \
    chromium \
    chromium-driver \
    build-essential \
    curl \
    libmagickwand-dev \
    imagemagick \
    xvfb \
    && rm -rf /var/lib/apt/lists/* && \
    # Verify Tesseract installation
    tesseract --version

# Set up display for headless environment
ENV DISPLAY=:99
ENV TESSDATA_PREFIX=/usr/share/tesseract-ocr/4.00/tessdata

# Set working directory
WORKDIR /app

# Copy Gemfile and Gemfile.lock
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies
RUN gem update --system && \
    gem install bundler && \
    bundle config set --local path '/usr/local/bundle' && \
    bundle config set --local without 'development:test' && \
    bundle install --jobs 4 --retry 3 && \
    # Clean up any stale Xvfb lock files
    rm -f /tmp/.X*-lock /tmp/.X11-unix/*

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

# Start the application using our script
CMD ["./start.sh"] 