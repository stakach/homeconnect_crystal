require "./spec_helper"
require "../src/homeconnect_local/runtime_builder"

class BuilderFakeTransport
  include HomeconnectLocal::Transport

  getter sent : Array(HomeconnectLocal::Message)

  def initialize
    @sent = [] of HomeconnectLocal::Message
  end

  def send_sync(msg : HomeconnectLocal::Message, timeout : Time::Span = 15.seconds) : HomeconnectLocal::Message
    @sent << msg
    HomeconnectLocal::Message.new(resource: msg.resource, action: HomeconnectLocal::Action::RESPONSE)
  end
end

describe HomeconnectLocal::Runtime::Builder do
  it "builds runtime entities from device description and handles services" do
    transport = BuilderFakeTransport.new
    device = HomeconnectLocal::DeviceDescription.new(
      status: [
        HomeconnectLocal::EntityDesc.new(uid: 100, name: "Test.BinarySensor", protocol_type: "Boolean"),
        HomeconnectLocal::EntityDesc.new(uid: 103, name: "Test.Sensor.Enum", protocol_type: "Integer", enum_map: {0 => "Off", 1 => "On"}),
      ],
      setting: [
        HomeconnectLocal::EntityDesc.new(uid: 201, name: "Test.Switch.Enum", protocol_type: "Integer", enum_map: {0 => "Off", 1 => "On"}),
        HomeconnectLocal::EntityDesc.new(uid: 203, name: "Test.Select", protocol_type: "Integer", enum_map: {0 => "Option1", 1 => "Option2", 2 => "Option3"}),
        HomeconnectLocal::EntityDesc.new(uid: 204, name: "Test.Number", protocol_type: "Integer", min: 0.0, max: 20.0, step: 2.0),
      ],
      command: [
        HomeconnectLocal::EntityDesc.new(uid: 300, name: "Test.AbortProgram", protocol_type: "Boolean"),
      ]
    )

    app = HomeconnectLocal::Runtime::Builder.from_device_description(
      device,
      transport,
      config: HomeconnectLocal::Runtime::Builder::BuildConfig.new(name_prefix: "test")
    )

    app.started?.should be_true

    app.call_service(
      "switch",
      "turn_on",
      {"entity_id" => JSON::Any.new(HomeconnectLocal::Runtime::Builder.entity_id_for("switch", "test", "Test.Switch.Enum"))}
    )
    sent_data = transport.sent.last.data[0].as_h
    sent_data["uid"].as_i.should eq(201)
    sent_data["value"].as_i.should eq(1)

    app.call_service(
      "select",
      "select_option",
      {
        "entity_id" => JSON::Any.new(HomeconnectLocal::Runtime::Builder.entity_id_for("select", "test", "Test.Select")),
        "option"    => JSON::Any.new("Option3"),
      }
    )
    sent_data = transport.sent.last.data[0].as_h
    sent_data["uid"].as_i.should eq(203)
    sent_data["value"].as_i.should eq(2)

    app.call_service(
      "number",
      "set_value",
      {
        "entity_id" => JSON::Any.new(HomeconnectLocal::Runtime::Builder.entity_id_for("number", "test", "Test.Number")),
        "value"     => JSON::Any.new("7"),
      }
    )
    sent_data = transport.sent.last.data[0].as_h
    sent_data["uid"].as_i.should eq(204)
    sent_data["value"].as_i.should eq(7)

    app.call_service(
      "button",
      "press",
      {"entity_id" => JSON::Any.new(HomeconnectLocal::Runtime::Builder.entity_id_for("button", "test", "Test.AbortProgram"))}
    )
    sent_data = transport.sent.last.data[0].as_h
    sent_data["uid"].as_i.should eq(300)
    sent_data["value"].as_bool.should be_true
  end

  it "builds selected/active/start program entities and start button payload" do
    transport = BuilderFakeTransport.new
    device = HomeconnectLocal::DeviceDescription.new(
      option: [
        HomeconnectLocal::EntityDesc.new(uid: 401, name: "Test.Option.1"),
        HomeconnectLocal::EntityDesc.new(uid: 402, name: "Test.Option.2"),
      ],
      program: [
        HomeconnectLocal::EntityDesc.new(uid: 500, name: "Test.Program.1", options: [401, 402]),
      ],
      selected_program: HomeconnectLocal::EntityDesc.new(uid: 250, name: "Test.SelectedProgram", protocol_type: "Integer"),
      active_program: HomeconnectLocal::EntityDesc.new(uid: 260, name: "Test.ActiveProgram", protocol_type: "Integer")
    )

    app = HomeconnectLocal::Runtime::Builder.from_device_description(
      device,
      transport,
      config: HomeconnectLocal::Runtime::Builder::BuildConfig.new(name_prefix: "test")
    )

    app.handle_values_notify(JSON.parse([{"uid" => 250, "value" => 500}].to_json))

    app.call_service(
      "button",
      "press",
      {"entity_id" => JSON::Any.new(HomeconnectLocal::Runtime::Builder.entity_id_for("button", "test", "StartProgram"))}
    )

    msg = transport.sent.last
    msg.resource.should eq("/ro/activeProgram")
    payload = msg.data[0].as_h
    payload["program"].as_i.should eq(500)
    options = payload["options"].as_a
    options.size.should eq(2)
    options[0].as_h["uid"].as_i.should eq(401)
    options[1].as_h["uid"].as_i.should eq(402)

    active_id = HomeconnectLocal::Runtime::Builder.entity_id_for("sensor", "test", "Test.ActiveProgram")
    app.handle_values_notify(JSON.parse([{"uid" => 260, "value" => 500}].to_json))
    active_state = app.state_store.get(active_id) || raise "missing active program state"
    active_state.state.should eq("Test.Program.1")
  end
end
