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

# Make start script executable
RUN chmod +x start.sh

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

# Start the application using our script
CMD ["./start.sh"] 