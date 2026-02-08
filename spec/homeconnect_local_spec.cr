require "./spec_helper"

describe HomeconnectLocal do
  it "has a version" do
    HomeconnectLocal::VERSION.should_not be_empty
  end

  it "can serialize a basic message" do
    msg = HomeconnectLocal::Message.new(resource: "/ci/info")
    json = msg.to_json_string
    json.should contain("\"resource\":\"/ci/info\"")
  end
end
