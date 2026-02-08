require "./spec_helper"
require "../src/homeconnect_local/entities"
require "../src/homeconnect_local/types"

# Fake transport for unit tests
class FakeTransport
  include HomeconnectLocal::Transport

  getter last_msg : HomeconnectLocal::Message?
  getter sent_msgs : Array(HomeconnectLocal::Message)

  def initialize
    @sent_msgs = [] of HomeconnectLocal::Message
  end

  def send_sync(msg : HomeconnectLocal::Message, timeout : Time::Span = 15.seconds) : HomeconnectLocal::Message
    @last_msg = msg
    @sent_msgs << msg
    # return a success response
    HomeconnectLocal::Message.new(
      resource: msg.resource,
      action: HomeconnectLocal::Action::RESPONSE,
      sid: 1_i64,
      msg_id: msg.msg_id || 1_i64,
      version: msg.version || 1,
      code: nil
    )
  end
end

describe HomeconnectLocal::Entity do
  it "POSTs /ro/values with uid + value" do
    t = FakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 2,
      name: "BSH.Common.Option.StartInRelative",
      protocol_type: "Integer",
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true
    )
    ent = HomeconnectLocal::Entity.new(desc, t)

    ent.value_raw = JSON::Any.new(120_i64)

    msg = t.last_msg || raise "expected last message to be recorded"
    msg.resource.should eq("/ro/values")
    msg.action.should eq(HomeconnectLocal::Action::POST)
    json = msg.to_json
    json.should contain("\"uid\":2")
    json.should contain("\"value\":120")
  end

  it "converts string payload to integer for Integer protocol" do
    t = FakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 204,
      name: "Test.Number",
      protocol_type: "Integer",
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true
    )
    ent = HomeconnectLocal::Entity.new(desc, t)

    ent.value_raw = JSON::Any.new("2")

    msg = t.last_msg || raise "expected last message to be recorded"
    msg.resource.should eq("/ro/values")
    payload = msg.data[0].as_h
    payload["uid"].as_i.should eq(204)
    payload["value"].as_i.should eq(2)
  end

  it "converts integer payload to boolean for Boolean protocol" do
    t = FakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 201,
      name: "Test.Switch",
      protocol_type: "Boolean",
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true
    )
    ent = HomeconnectLocal::Entity.new(desc, t)

    ent.value_raw = JSON::Any.new(1_i64)

    msg = t.last_msg || raise "expected last message to be recorded"
    payload = msg.data[0].as_h
    payload["uid"].as_i.should eq(201)
    payload["value"].as_bool.should be_true
  end

  it "maps enum value to string representation" do
    t = FakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 203,
      name: "Test.Select",
      protocol_type: "Integer",
      enum_map: {0 => "Option1", 1 => "Option2", 2 => "Option3"},
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true
    )
    ent = HomeconnectLocal::Entity.new(desc, t)

    ent.update_from_hash({"value" => JSON::Any.new(1_i64)})

    val = ent.value || raise "expected mapped value"
    val.as_s.should eq("Option2")
  end

  it "updates number bounds and step from payload" do
    t = FakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 204,
      name: "Test.Number",
      protocol_type: "Integer",
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true
    )
    ent = HomeconnectLocal::Entity.new(desc, t)

    ent.update_from_hash({
      "min"      => JSON::Any.new(10_i64),
      "max"      => JSON::Any.new(50_i64),
      "stepSize" => JSON::Any.new(5_i64),
    })

    ent.min.should eq(10.0)
    ent.max.should eq(50.0)
    ent.step.should eq(5.0)
  end
end

describe HomeconnectLocal::Program do
  it "POSTs /ro/selectedProgram with empty options" do
    t = FakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 501,
      name: "Test.Program.Program2",
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true
    )
    prog = HomeconnectLocal::Program.new(desc, t)

    prog.select

    msg = t.last_msg || raise "expected last message to be recorded"
    msg.resource.should eq("/ro/selectedProgram")
    msg.action.should eq(HomeconnectLocal::Action::POST)
    payload = msg.data[0].as_h
    payload["program"].as_i.should eq(501)
    payload["options"].as_a.should be_empty
  end

  it "POSTs /ro/activeProgram with explicit options" do
    t = FakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 502,
      name: "Test.Program.Program3",
      options: [401, 402],
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true
    )
    prog = HomeconnectLocal::Program.new(desc, t)

    prog.start({401 => JSON::Any.new(nil), 402 => JSON::Any.new(50_i64)})

    msg = t.last_msg || raise "expected last message to be recorded"
    msg.resource.should eq("/ro/activeProgram")
    msg.action.should eq(HomeconnectLocal::Action::POST)
    payload = msg.data[0].as_h
    payload["program"].as_i.should eq(502)
    options = payload["options"].as_a
    options.size.should eq(2)
    options[0].as_h["uid"].as_i.should eq(401)
    options[0].as_h["value"].raw.should be_nil
    options[1].as_h["uid"].as_i.should eq(402)
    options[1].as_h["value"].as_i.should eq(50)
  end

  it "fills missing option values from shadow state when not overridden" do
    t = FakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 502,
      name: "Test.Program.Program3",
      options: [401, 402],
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true
    )
    prog = HomeconnectLocal::Program.new(desc, t)

    opt401 = HomeconnectLocal::Entity.new(
      HomeconnectLocal::EntityDesc.new(
        uid: 401,
        name: "Test.Option.One",
        protocol_type: "Integer",
        access: HomeconnectLocal::Access::READ_WRITE,
        available: true
      ),
      t
    )
    opt402 = HomeconnectLocal::Entity.new(
      HomeconnectLocal::EntityDesc.new(
        uid: 402,
        name: "Test.Option.Two",
        protocol_type: "Integer",
        access: HomeconnectLocal::Access::READ_WRITE,
        available: true
      ),
      t
    )
    opt401.update_from_hash({"value" => JSON::Any.new(10_i64)})
    opt402.update_from_hash({"value" => JSON::Any.new(20_i64)})

    entities = {401 => opt401, 402 => opt402}
    prog.start({401 => JSON::Any.new(99_i64)}, override_options: false, entities_by_uid: entities)

    msg = t.last_msg || raise "expected last message to be recorded"
    payload = msg.data[0].as_h
    options = payload["options"].as_a
    options.size.should eq(2)
    options[0].as_h["uid"].as_i.should eq(401)
    options[0].as_h["value"].as_i.should eq(99)
    options[1].as_h["uid"].as_i.should eq(402)
    options[1].as_h["value"].as_i.should eq(20)
  end
end
