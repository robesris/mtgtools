require 'rspec'
require 'spec_helper'
require 'rack/test'

describe "DRANNITH MAGISTRATE price (including shipping)" do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  it "fetches DRANNITH MAGISTRATE's prices (Near Mint: $15.94 (included shipping), Lightly Played: $17.28 (15.59 + 1.69 shipping))" do
    get "/card_info?card=DRANNITH MAGISTRATE"
    expect(last_response).to be_ok
    data = JSON.parse(last_response.body)
    expect(data["prices"]["Near Mint"]).to eq("15.94")
    expect(data["prices"]["Lightly Played"]).to eq("17.28")
  end
end 