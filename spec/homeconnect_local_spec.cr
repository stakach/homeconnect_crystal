require "./spec_helper"

describe HomeconnectLocal do
  it "has a version" do
    HomeconnectLocal::VERSION.should_not be_empty
  end

  it "can serialize a basic message" do
    msg = HomeconnectLocal::Message.new(resource: "/ci/info")
    json = msg.to_json
    json.should contain("\"resource\":\"/ci/info\"")
  end

  it "parses initialValues payload with large IDs" do
    payload = %({"sID":1104548025,"msgID":3717240202,"resource":"/ei/initialValues","version":2,"action":"POST","data":[{"edMsgID":4282959678}]})

    msg = HomeconnectLocal::Message.from_json(payload)

    msg.sid.should eq(1_104_548_025_i64)
    msg.msg_id.should eq(3_717_240_202_i64)
    msg.resource.should eq("/ei/initialValues")
    msg.version.should eq(2)
    msg.action.should eq(HomeconnectLocal::Action::POST)
    msg.data[0].as_h["edMsgID"].as_i64.should eq(4_282_959_678_i64)
  end

  it "parses messages without optional fields" do
    payload = %({"resource":"/ro/values","action":"NOTIFY","data":[]})

    msg = HomeconnectLocal::Message.from_json(payload)

    msg.resource.should eq("/ro/values")
    msg.action.should eq(HomeconnectLocal::Action::NOTIFY)
    msg.sid.should be_nil
    msg.msg_id.should be_nil
    msg.version.should be_nil
  end

  it "sets keepalive uid from first setting description entry" do
    client = HomeconnectLocal::Client.new(
      host: "127.0.0.1",
      psk64: "AQIDBA",
      mode: HomeconnectLocal::TransportMode::TLS_PSK
    )

    desc = HomeconnectLocal::DeviceDescription.new(
      setting: [
        HomeconnectLocal::EntityDesc.new(uid: 0x17c0, name: "Cooking.Oven.Status.Cavity.001.ActiveProgram"),
        HomeconnectLocal::EntityDesc.new(uid: 0x17c1, name: "Setting.Two"),
      ]
    )

    client.keepalive_status_from_description = desc
    client.keepalive_status_uid.should eq(0x17c0)
  end

  it "clears keepalive uid when status description is empty" do
    client = HomeconnectLocal::Client.new(
      host: "127.0.0.1",
      psk64: "AQIDBA",
      mode: HomeconnectLocal::TransportMode::TLS_PSK,
      keepalive_status_uid: 0x0200
    )

    desc = HomeconnectLocal::DeviceDescription.new
    client.keepalive_status_from_description = desc
    client.keepalive_status_uid.should be_nil
  end

  it "falls back to readable status when settings are missing" do
    client = HomeconnectLocal::Client.new(
      host: "127.0.0.1",
      psk64: "AQIDBA",
      mode: HomeconnectLocal::TransportMode::TLS_PSK
    )

    desc = HomeconnectLocal::DeviceDescription.new(
      status: [
        HomeconnectLocal::EntityDesc.new(uid: 0x0200, name: "Status.One", access: HomeconnectLocal::Access::NONE, available: false),
        HomeconnectLocal::EntityDesc.new(uid: 0x0201, name: "Status.Two", access: HomeconnectLocal::Access::READ, available: true),
      ]
    )

    client.keepalive_status_from_description = desc
    client.keepalive_status_uid.should eq(0x0201)
  end
end
