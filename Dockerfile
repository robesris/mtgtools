FROM ruby:3.4.3-slim

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    chromium \
    chromium-driver \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy Gemfile and Gemfile.lock
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies
RUN bundle install

# Copy the rest of the application
COPY . .

# Set environment variables
ENV RACK_ENV=production
ENV DEBUG_MODE=false
ENV PORT=10000

# Expose the port
EXPOSE 10000

# Start the application
CMD ["bundle", "exec", "rackup", "config.ru", "-o", "0.0.0.0", "-p", "10000"] 