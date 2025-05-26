require 'bundler/setup'
require 'httparty'
require 'json'
require 'fileutils'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Clean up any temporary files after each test
  config.after(:suite) do
    FileUtils.rm_rf('debug_screenshots')
    FileUtils.rm_rf('test_screenshots')
  end
end 