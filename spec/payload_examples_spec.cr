require "./spec_helper"

describe "Payload examples from homeconnect_local_hass" do
  it "serializes switch on payload" do
    msg = HomeconnectLocal::Message.new(
      resource: "/ro/values",
      action: HomeconnectLocal::Action::POST,
      data: JSON.parse([{"uid" => 201, "value" => true}].to_json).as_a
    )

    json = msg.to_json
    json.should contain("\"resource\":\"/ro/values\"")
    json.should contain("\"data\":[{\"uid\":201,\"value\":true}]")
  end

  it "serializes fan speed payload as multi-entry data array" do
    msg = HomeconnectLocal::Message.new(
      resource: "/ro/values",
      action: HomeconnectLocal::Action::POST,
      data: JSON.parse([{"uid" => 403, "value" => 1}, {"uid" => 404, "value" => 0}].to_json).as_a
    )

    json = msg.to_json
    json.should contain("\"data\":[{\"uid\":403,\"value\":1},{\"uid\":404,\"value\":0}]")
  end

  it "serializes light on payload as single-entry array" do
    msg = HomeconnectLocal::Message.new(
      resource: "/ro/values",
      action: HomeconnectLocal::Action::POST,
      data: JSON.parse([{"uid" => 108, "value" => true}].to_json).as_a
    )

    json = msg.to_json
    json.should contain("\"data\":[{\"uid\":108,\"value\":true}]")
  end

  it "round-trips light brightness plus color temperature payload" do
    raw = {
      "resource" => "/ro/values",
      "action"   => "POST",
      "data"     => [
        {"uid" => 109, "value" => 100},
        {"uid" => 110, "value" => 100},
        {"uid" => 108, "value" => true},
      ],
    }.to_json

    msg = HomeconnectLocal::Message.from_json(raw)

    msg.resource.should eq("/ro/values")
    msg.action.should eq(HomeconnectLocal::Action::POST)
    arr = msg.data
    arr.size.should eq(3)
    arr[0].as_h["uid"].as_i.should eq(109)
    arr[0].as_h["value"].as_i.should eq(100)
    arr[1].as_h["uid"].as_i.should eq(110)
    arr[1].as_h["value"].as_i.should eq(100)
    arr[2].as_h["uid"].as_i.should eq(108)
    arr[2].as_h["value"].as_bool.should be_true
  end

  it "serializes light RGB hex payload" do
    msg = HomeconnectLocal::Message.new(
      resource: "/ro/values",
      action: HomeconnectLocal::Action::POST,
      data: JSON.parse([{"uid" => 111, "value" => "#008000"}].to_json).as_a
    )

    json = msg.to_json
    json.should contain("\"data\":[{\"uid\":111,\"value\":\"#008000\"}]")
  end
end
