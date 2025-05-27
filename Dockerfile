FROM ruby:3.4.3-slim

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    chromium \
    chromium-driver \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy Gemfile and Gemfile.lock
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies
RUN bundle install --jobs 4 --retry 3

# Copy the rest of the application
COPY . .

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