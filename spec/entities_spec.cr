require "./spec_helper"
require "../src/entities"
require "../src/types"

# Fake transport for unit tests
class FakeTransport
  include HomeconnectLocal::Transport

  getter last_msg : HomeconnectLocal::Message?

  def send_sync(msg : HomeconnectLocal::Message, timeout : Time::Span = 15.seconds) : HomeconnectLocal::Message
    @last_msg = msg
    # return a success response
    HomeconnectLocal::Message.new(
      resource: msg.resource,
      action: HomeconnectLocal::Action::RESPONSE,
      sid: 1_i64,
      msg_id: msg.msg_id || 1_i64,
      version: msg.version || 1,
      data: nil,
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

    ent.set_value_raw(JSON::Any.new(120_i64))

    msg = t.last_msg.not_nil!
    msg.resource.should eq("/ro/values")
    msg.action.should eq(HomeconnectLocal::Action::POST)
    json = msg.to_json_string
    json.should contain("\"uid\":2")
    json.should contain("\"value\":120")
  end
end
