require "./spec_helper"
require "../src/homeconnect_local/runtime"

class RuntimeFakeTransport
  include HomeconnectLocal::Transport

  getter sent : Array(HomeconnectLocal::Message)

  def initialize
    @sent = [] of HomeconnectLocal::Message
  end

  def send_sync(msg : HomeconnectLocal::Message, timeout : Time::Span = 15.seconds) : HomeconnectLocal::Message
    @sent << msg
    HomeconnectLocal::Message.new(
      resource: msg.resource,
      action: HomeconnectLocal::Action::RESPONSE
    )
  end
end

describe HomeconnectLocal::Runtime::RuntimeApp do
  it "handles lifecycle start and stop" do
    app = HomeconnectLocal::Runtime::RuntimeApp.new
    app.started?.should be_false
    app.start
    app.started?.should be_true
    app.stop
    app.started?.should be_false
  end

  it "routes switch service calls through bus and updates state" do
    transport = RuntimeFakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 201,
      name: "Test.Switch",
      protocol_type: "Boolean",
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true
    )
    entity = HomeconnectLocal::Entity.new(desc, transport)
    switch_entity = HomeconnectLocal::Runtime::SwitchEntity.new(
      entity,
      entity_id: "switch.test_switch",
      friendly_name: "Test Switch"
    )

    app = HomeconnectLocal::Runtime::RuntimeApp.new
    app.register_entity(switch_entity)
    app.start

    app.call_service(
      "switch",
      "turn_on",
      {"entity_id" => JSON::Any.new("switch.test_switch")}
    )

    sent = transport.sent.last
    payload = sent.data[0].as_h
    payload["uid"].as_i.should eq(201)
    payload["value"].as_bool.should be_true

    state = app.state_store.get("switch.test_switch") || raise "missing state"
    state.state.should eq("on")
  end

  it "routes select option service and reflects notify updates in state store" do
    transport = RuntimeFakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 203,
      name: "Test.Select",
      protocol_type: "Integer",
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true
    )
    entity = HomeconnectLocal::Entity.new(desc, transport)
    select_entity = HomeconnectLocal::Runtime::SelectEntity.new(
      entity,
      entity_id: "select.test_select",
      friendly_name: "Test Select",
      option_to_value: {
        "Option1" => JSON::Any.new(0_i64),
        "Option2" => JSON::Any.new(1_i64),
        "Option3" => JSON::Any.new(2_i64),
      }
    )

    app = HomeconnectLocal::Runtime::RuntimeApp.new
    app.register_entity(select_entity)
    app.start

    app.call_service(
      "select",
      "select_option",
      {
        "entity_id" => JSON::Any.new("select.test_select"),
        "option"    => JSON::Any.new("Option3"),
      }
    )
    sent = transport.sent.last
    sent_data = sent.data[0].as_h
    sent_data["value"].as_i.should eq(2)

    app.handle_values_notify(JSON.parse([{"uid" => 203, "value" => 1}].to_json))
    state = app.state_store.get("select.test_select") || raise "missing state"
    state.state.should eq("Option2")
  end

  it "routes number service and tracks min/max/step in attributes" do
    transport = RuntimeFakeTransport.new
    desc = HomeconnectLocal::EntityDesc.new(
      uid: 204,
      name: "Test.Number",
      protocol_type: "Integer",
      access: HomeconnectLocal::Access::READ_WRITE,
      available: true,
      min: 0.0,
      max: 20.0,
      step: 2.0
    )
    entity = HomeconnectLocal::Entity.new(desc, transport)
    number_entity = HomeconnectLocal::Runtime::NumberEntity.new(
      entity,
      entity_id: "number.test_number",
      friendly_name: "Test Number"
    )

    app = HomeconnectLocal::Runtime::RuntimeApp.new
    app.register_entity(number_entity)
    app.start

    app.call_service(
      "number",
      "set_value",
      {
        "entity_id" => JSON::Any.new("number.test_number"),
        "value"     => JSON::Any.new("2"),
      }
    )

    sent = transport.sent.last
    sent_data = sent.data[0].as_h
    sent_data["value"].as_i.should eq(2)

    state = app.state_store.get("number.test_number") || raise "missing state"
    state.state.should eq("2")
    state.attributes["min"].as_f.should eq(0.0)
    state.attributes["max"].as_f.should eq(20.0)
    state.attributes["step"].as_f.should eq(2.0)
  end

  it "updates binary sensor states from bool and enum payloads" do
    transport = RuntimeFakeTransport.new
    bool_desc = HomeconnectLocal::EntityDesc.new(
      uid: 100,
      name: "Test.BinarySensor",
      protocol_type: "Boolean",
      access: HomeconnectLocal::Access::READ,
      available: true
    )
    enum_desc = HomeconnectLocal::EntityDesc.new(
      uid: 101,
      name: "Test.BinarySensor.Enum",
      protocol_type: "Integer",
      access: HomeconnectLocal::Access::READ,
      available: true
    )
    bool_entity = HomeconnectLocal::Entity.new(bool_desc, transport)
    enum_entity = HomeconnectLocal::Entity.new(enum_desc, transport)

    bs = HomeconnectLocal::Runtime::BinarySensorEntity.new(
      bool_entity,
      entity_id: "binary_sensor.test_bool",
      friendly_name: "Bool Sensor"
    )
    bs_enum = HomeconnectLocal::Runtime::BinarySensorEntity.new(
      enum_entity,
      entity_id: "binary_sensor.test_enum",
      friendly_name: "Enum Sensor",
      value_on: ["1", "On"],
      value_off: ["0", "Off"]
    )

    app = HomeconnectLocal::Runtime::RuntimeApp.new
    app.register_entity(bs)
    app.register_entity(bs_enum)
    app.start

    app.handle_values_notify(JSON.parse([{"uid" => 100, "value" => true}, {"uid" => 101, "value" => 0}].to_json))
    bool_state = app.state_store.get("binary_sensor.test_bool") || raise "missing bool state"
    enum_state = app.state_store.get("binary_sensor.test_enum") || raise "missing enum state"
    bool_state.state.should eq("on")
    enum_state.state.should eq("off")

    app.handle_values_notify(JSON.parse([{"uid" => 100, "value" => false}, {"uid" => 101, "value" => 1}].to_json))
    bool_state = app.state_store.get("binary_sensor.test_bool") || raise "missing bool state"
    enum_state = app.state_store.get("binary_sensor.test_enum") || raise "missing enum state"
    bool_state.state.should eq("off")
    enum_state.state.should eq("on")
  end

  it "updates sensor values and enum mapping state" do
    transport = RuntimeFakeTransport.new
    num_desc = HomeconnectLocal::EntityDesc.new(
      uid: 102,
      name: "Test.Sensor",
      protocol_type: "Integer",
      access: HomeconnectLocal::Access::READ,
      available: true
    )
    enum_desc = HomeconnectLocal::EntityDesc.new(
      uid: 103,
      name: "Test.Sensor.Enum",
      protocol_type: "Integer",
      enum_map: {0 => "Off", 1 => "On"},
      access: HomeconnectLocal::Access::READ,
      available: true
    )
    num_entity = HomeconnectLocal::Entity.new(num_desc, transport)
    enum_entity = HomeconnectLocal::Entity.new(enum_desc, transport)

    sensor = HomeconnectLocal::Runtime::SensorEntity.new(
      num_entity,
      entity_id: "sensor.test_number",
      friendly_name: "Sensor"
    )
    sensor_enum = HomeconnectLocal::Runtime::SensorEntity.new(
      enum_entity,
      entity_id: "sensor.test_enum",
      friendly_name: "Sensor.Enum",
      options: ["Off", "On"]
    )

    app = HomeconnectLocal::Runtime::RuntimeApp.new
    app.register_entity(sensor)
    app.register_entity(sensor_enum)
    app.start

    app.handle_values_notify(JSON.parse([{"uid" => 102, "value" => 5}, {"uid" => 103, "value" => 1}].to_json))

    num_state = app.state_store.get("sensor.test_number") || raise "missing numeric sensor state"
    enum_state = app.state_store.get("sensor.test_enum") || raise "missing enum sensor state"
    num_state.state.should eq("5")
    enum_state.state.should eq("On")
    enum_state.attributes["options"].as_a.size.should eq(2)
  end

  it "maps fan percentage to multi-uid payload and updates state" do
    transport = RuntimeFakeTransport.new
    s1 = HomeconnectLocal::Entity.new(
      HomeconnectLocal::EntityDesc.new(uid: 403, name: "Test.FanSpeed1", protocol_type: "Integer", access: HomeconnectLocal::Access::READ_WRITE, available: true),
      transport
    )
    s2 = HomeconnectLocal::Entity.new(
      HomeconnectLocal::EntityDesc.new(uid: 404, name: "Test.FanSpeed2", protocol_type: "Integer", access: HomeconnectLocal::Access::READ_WRITE, available: true),
      transport
    )
    fan = HomeconnectLocal::Runtime::FanEntity.new(
      transport,
      s1,
      s2,
      entity_id: "fan.test_fan",
      friendly_name: "Test Fan"
    )

    app = HomeconnectLocal::Runtime::RuntimeApp.new
    app.register_entity(fan)
    app.start

    app.call_service("fan", "set_percentage", {"entity_id" => JSON::Any.new("fan.test_fan"), "percentage" => JSON::Any.new(75)})
    sent = transport.sent.last
    sent.resource.should eq("/ro/values")
    arr = sent.data
    arr.size.should eq(2)
    arr[0].as_h["uid"].as_i.should eq(403)
    arr[0].as_h["value"].as_i.should eq(0)
    arr[1].as_h["uid"].as_i.should eq(404)
    arr[1].as_h["value"].as_i.should eq(1)

    state = app.state_store.get("fan.test_fan") || raise "missing fan state"
    state.state.should eq("on")
    state.attributes["percentage"].as_i.should eq(75)
  end

  it "builds light payloads for on, brightness and color temperature" do
    transport = RuntimeFakeTransport.new
    power = HomeconnectLocal::Entity.new(
      HomeconnectLocal::EntityDesc.new(uid: 108, name: "Test.Lighting", protocol_type: "Boolean", access: HomeconnectLocal::Access::READ_WRITE, available: true),
      transport
    )
    brightness = HomeconnectLocal::Entity.new(
      HomeconnectLocal::EntityDesc.new(uid: 109, name: "Test.LightingBrightness", protocol_type: "Integer", access: HomeconnectLocal::Access::READ_WRITE, available: true),
      transport
    )
    color_temp = HomeconnectLocal::Entity.new(
      HomeconnectLocal::EntityDesc.new(uid: 110, name: "Test.LightingColorTempPercent", protocol_type: "Integer", access: HomeconnectLocal::Access::READ_WRITE, available: true),
      transport
    )
    light = HomeconnectLocal::Runtime::LightEntity.new(
      transport,
      power,
      entity_id: "light.test_light",
      friendly_name: "Test Light",
      brightness: brightness,
      color_temp_percent: color_temp
    )

    app = HomeconnectLocal::Runtime::RuntimeApp.new
    app.register_entity(light)
    app.start

    app.call_service("light", "turn_on", {"entity_id" => JSON::Any.new("light.test_light")})
    on_payload = transport.sent.last.data
    on_payload[0].as_h["uid"].as_i.should eq(108)
    on_payload[0].as_h["value"].as_bool.should be_true

    app.call_service(
      "light",
      "turn_on",
      {
        "entity_id"         => JSON::Any.new("light.test_light"),
        "brightness_pct"    => JSON::Any.new(50),
        "color_temp_kelvin" => JSON::Any.new(4268),
      }
    )
    arr = transport.sent.last.data
    arr[0].as_h["uid"].as_i.should eq(109)
    arr[0].as_h["value"].as_i.should eq(50)
    arr[1].as_h["uid"].as_i.should eq(110)
    arr[1].as_h["value"].as_i.should eq(50)
  end

  it "presses abort and start-program buttons with expected payloads" do
    transport = RuntimeFakeTransport.new

    abort_entity = HomeconnectLocal::Entity.new(
      HomeconnectLocal::EntityDesc.new(uid: 300, name: "Test.AbortProgram", protocol_type: "Boolean", access: HomeconnectLocal::Access::READ_WRITE, available: true),
      transport
    )
    abort_button = HomeconnectLocal::Runtime::ButtonEntity.new(
      abort_entity,
      entity_id: "button.abort",
      friendly_name: "Abort"
    )

    selected_program = HomeconnectLocal::Entity.new(
      HomeconnectLocal::EntityDesc.new(uid: 250, name: "Test.SelectedProgram", protocol_type: "Integer", access: HomeconnectLocal::Access::READ_WRITE, available: true),
      transport
    )
    program = HomeconnectLocal::Program.new(
      HomeconnectLocal::EntityDesc.new(uid: 500, name: "Test.Program", options: [401, 402], access: HomeconnectLocal::Access::READ_WRITE, available: true),
      transport
    )
    start_button = HomeconnectLocal::Runtime::StartProgramButtonEntity.new(
      selected_program,
      {500 => program},
      entity_id: "button.start",
      friendly_name: "Start"
    )

    app = HomeconnectLocal::Runtime::RuntimeApp.new
    app.register_entity(abort_button)
    app.register_entity(start_button)
    app.start

    app.call_service("button", "press", {"entity_id" => JSON::Any.new("button.abort")})
    abort_payload = transport.sent.last.data[0].as_h
    abort_payload["uid"].as_i.should eq(300)
    abort_payload["value"].as_bool.should be_true

    app.handle_values_notify(JSON.parse([{"uid" => 250, "value" => 500}].to_json))
    app.call_service("button", "press", {"entity_id" => JSON::Any.new("button.start")})
    start_msg = transport.sent.last
    start_msg.resource.should eq("/ro/activeProgram")
    start_payload = start_msg.data[0].as_h
    start_payload["program"].as_i.should eq(500)
    options = start_payload["options"].as_a
    options.size.should eq(2)
    options[0].as_h["uid"].as_i.should eq(401)
    options[0].as_h["value"].raw.should be_nil
    options[1].as_h["uid"].as_i.should eq(402)
    options[1].as_h["value"].raw.should be_nil
  end
end
