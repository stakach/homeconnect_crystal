require "option_parser"
require "json"

require "../src/homeconnect_local"

private def prompt(label : String) : String?
  print "#{label}> "
  STDIN.gets.try(&.strip)
end

class OvenCtl
  STATUS_FIELDS = [
    "BSH.Common.Status.OperationState",
    "BSH.Common.Status.DoorState",
    "Cooking.Oven.Status.Cavity.001.CurrentTemperature",
    "BSH.Common.Status.Camera.001.State",
    "BSH.Common.Setting.PowerState",
  ]

  MICROWAVE_PROGRAM           = "Cooking.Oven.Program.Microwave.Max"
  PREHEAT_PROGRAM             = "Cooking.Oven.Program.HeatingMode.PreHeating"
  OPTION_DURATION             = "BSH.Common.Option.Duration"
  OPTION_SETPOINT_TEMPERATURE = "Cooking.Oven.Option.SetpointTemperature"
  COMMAND_PAUSE               = "BSH.Common.Command.PauseProgram"
  COMMAND_RESUME              = "BSH.Common.Command.ResumeProgram"
  COMMAND_STOP                = "BSH.Common.Command.AbortProgram"
  COMMAND_TAKE_PHOTO          = "BSH.Common.Command.Camera.001.TakeSnapshot"
  SETTING_POWER               = "BSH.Common.Setting.PowerState"

  @description : HomeconnectLocal::DeviceDescription
  @client : HomeconnectLocal::Client
  @name_to_desc : Hash(String, HomeconnectLocal::EntityDesc)
  @entities_by_uid : Hash(Int32, HomeconnectLocal::Entity)
  @values_by_uid : Hash(Int32, JSON::Any)

  def initialize(
    ip : String,
    psk64 : String,
    identity : String,
    cipher : String,
    device_xml_path : String,
    feature_xml_path : String,
    debug_frames : Bool = false,
  )
    device_xml = File.read(device_xml_path)
    feature_xml = File.read(feature_xml_path)
    @description = HomeconnectLocal::Parser.parse_device_description(device_xml, feature_xml)

    @client = HomeconnectLocal::Client.new(
      host: ip,
      psk64: psk64,
      mode: HomeconnectLocal::TransportMode::TLS_PSK,
      psk_identity: identity,
      tls_cipher: cipher,
      app_name: "oven_ctl"
    )
    @client.debug_frames = debug_frames
    @client.keepalive_status_from_description = @description

    @name_to_desc = {} of String => HomeconnectLocal::EntityDesc
    @entities_by_uid = {} of Int32 => HomeconnectLocal::Entity
    @values_by_uid = {} of Int32 => JSON::Any

    register_all_entities
  end

  def connect
    @client.connect
    refresh_description_changes
    refresh_values
  end

  def close
    @client.close
  end

  def status : Hash(String, JSON::Any)
    refresh_values
    out = {} of String => JSON::Any
    STATUS_FIELDS.each do |name|
      desc = desc_for(name)
      out[name] = formatted_value(desc, @values_by_uid[desc.uid]?)
    end
    out
  end

  def microwave(seconds : Int32)
    duration = seconds.clamp(1, 86_400)
    program = program_for(MICROWAVE_PROGRAM)
    options = {
      option_for(OPTION_DURATION).uid => JSON::Any.new(duration.to_i64),
    }
    program.start(options, override_options: true)
  end

  def preheat(celsius : Int32)
    temperature = celsius.clamp(30, 300)
    program = program_for(PREHEAT_PROGRAM)
    options = {
      option_for(OPTION_SETPOINT_TEMPERATURE).uid => JSON::Any.new(temperature.to_i64),
      option_for(OPTION_DURATION).uid             => JSON::Any.new(3600_i64),
    }
    program.start(options, override_options: true)
  end

  def pause
    command_for(COMMAND_PAUSE).value_raw = JSON::Any.new(true)
  end

  def resume
    command_for(COMMAND_RESUME).value_raw = JSON::Any.new(true)
  end

  def stop
    command_for(COMMAND_STOP).value_raw = JSON::Any.new(true)
  end

  def take_photo
    command_for(COMMAND_TAKE_PHOTO).value_raw = JSON::Any.new(true)
  end

  def power(target_on : Bool)
    refresh_values
    setting_desc = desc_for(SETTING_POWER)
    enum_map = setting_desc.enum_map || raise "Missing enum map for #{SETTING_POWER}"
    on_code = enum_code_for(enum_map, "On") || raise "Missing enum value 'On' for #{SETTING_POWER}"
    off_code = enum_code_for(enum_map, "Standby") || enum_map.keys.find { |k| k != on_code } || raise "No non-On value for #{SETTING_POWER}"

    current_raw = @values_by_uid[setting_desc.uid]?
    current_code = any_to_i32(current_raw)
    current_on = current_code == on_code

    return if target_on == current_on

    target_code = target_on ? on_code : off_code
    setting_for(SETTING_POWER).value_raw = JSON::Any.new(target_code.to_i64)
  end

  private def register_all_entities
    all = @description.status + @description.setting + @description.event + @description.command + @description.option + @description.program
    all.each do |desc|
      @name_to_desc[desc.name] = desc
      @entities_by_uid[desc.uid] = HomeconnectLocal::Entity.new(desc, @client)
    end
    if ap = @description.active_program
      @name_to_desc[ap.name] = ap
      @entities_by_uid[ap.uid] = HomeconnectLocal::Entity.new(ap, @client)
    end
    if sp = @description.selected_program
      @name_to_desc[sp.name] = sp
      @entities_by_uid[sp.uid] = HomeconnectLocal::Entity.new(sp, @client)
    end
  end

  private def refresh_values
    rsp = @client.send_sync(HomeconnectLocal::Message.new(resource: "/ro/allMandatoryValues", action: HomeconnectLocal::Action::GET))
    apply_payload(rsp.data)
  end

  private def refresh_description_changes
    rsp = @client.send_sync(HomeconnectLocal::Message.new(resource: "/ro/allDescriptionChanges", action: HomeconnectLocal::Action::GET))
    apply_payload(rsp.data)
  end

  private def apply_payload(data : Array(JSON::Any))
    data.each do |entry_any|
      entry = entry_any.as_h?
      next unless entry

      uid = any_to_i32(entry["uid"]?)
      next unless uid

      @entities_by_uid[uid]?.try(&.update_from_hash(entry))
      if value = entry["value"]?
        @values_by_uid[uid] = value
      end
    end
  end

  private def desc_for(name : String) : HomeconnectLocal::EntityDesc
    @name_to_desc[name]? || raise "Entity not found in XML: #{name}"
  end

  private def program_for(name : String) : HomeconnectLocal::Program
    desc = desc_for(name)
    HomeconnectLocal::Program.new(desc, @client)
  end

  private def command_for(name : String) : HomeconnectLocal::Entity
    entity_for(name)
  end

  private def setting_for(name : String) : HomeconnectLocal::Entity
    entity_for(name)
  end

  private def option_for(name : String) : HomeconnectLocal::EntityDesc
    desc_for(name)
  end

  private def entity_for(name : String) : HomeconnectLocal::Entity
    desc = desc_for(name)
    @entities_by_uid[desc.uid]? || raise "Entity missing for #{name}"
  end

  private def enum_code_for(enum_map : Hash(Int32, String), label : String) : Int32?
    enum_map.find { |_, v| v.downcase == label.downcase }.try(&.[0])
  end

  private def formatted_value(desc : HomeconnectLocal::EntityDesc, raw : JSON::Any?) : JSON::Any
    return JSON::Any.new(nil) unless raw
    if enum_map = desc.enum_map
      if int_value = any_to_i32(raw)
        if label = enum_map[int_value]?
          return JSON::Any.new(label)
        end
      end
    end
    raw
  end

  private def any_to_i32(any : JSON::Any?) : Int32?
    return nil unless any
    case v = any.raw
    when Int32
      v
    when Int64
      return nil if v < Int32::MIN || v > Int32::MAX
      v.to_i32
    when Float64
      i = v.to_i64
      return nil if i < Int32::MIN || i > Int32::MAX
      i.to_i32
    when String
      v.to_i32?
    else
      nil
    end
  end
end

ip = "192.168.4.79"
psk64 = ""
identity = "homeconnect"
cipher = "PSK"
device_xml_path : String? = nil
feature_xml_path : String? = nil
debug_frames = false

OptionParser.parse do |opts|
  opts.banner = "Usage: crystal run examples/oven_ctl.cr -- [global options] <command> [args]"
  opts.on("--ip=IP", "Oven IP address (default #{ip})") { |v| ip = v }
  opts.on("--psk64=KEY", "PSK in urlsafe base64 (required)") { |v| psk64 = v }
  opts.on("--identity=ID", "PSK identity string (default #{identity})") { |v| identity = v }
  opts.on("--cipher=CIPHER", "TLS1.2 PSK cipher string (default #{cipher})") { |v| cipher = v }
  opts.on("--device-xml=PATH", "Path to DeviceDescription.xml (required)") { |v| device_xml_path = v }
  opts.on("--feature-xml=PATH", "Path to FeatureMapping.xml (required)") { |v| feature_xml_path = v }
  opts.on("--debug-frames", "Enable websocket frame-level logging") { debug_frames = true }
  opts.on("-h", "--help", "Show help") { puts opts; exit }
end

if psk64.empty?
  STDERR.puts "--psk64 is required"
  exit 2
end

unless device_xml_path && feature_xml_path
  STDERR.puts "--device-xml and --feature-xml are required"
  exit 2
end

command = ARGV.shift?

controller = OvenCtl.new(
  ip: ip,
  psk64: psk64,
  identity: identity,
  cipher: cipher,
  device_xml_path: device_xml_path.as(String),
  feature_xml_path: feature_xml_path.as(String),
  debug_frames: debug_frames
)

controller.connect

begin
  if command
    case command
    when "status"
      puts controller.status.to_json
    when "microwave"
      seconds_arg = ARGV.shift? || raise "microwave requires seconds"
      controller.microwave(seconds_arg.to_i)
      puts %({"ok":true,"command":"microwave","seconds":#{seconds_arg.to_i}})
    when "preheat"
      temp_arg = ARGV.shift? || raise "preheat requires celsius"
      controller.preheat(temp_arg.to_i)
      puts %({"ok":true,"command":"preheat","celsius":#{temp_arg.to_i},"duration_seconds":3600})
    when "pause"
      controller.pause
      puts %({"ok":true,"command":"pause"})
    when "resume"
      controller.resume
      puts %({"ok":true,"command":"resume"})
    when "stop"
      controller.stop
      puts %({"ok":true,"command":"stop"})
    when "power"
      raw = ARGV.shift? || raise "power requires true|false"
      target = case raw.downcase
               when "true", "1", "on", "yes"  then true
               when "false", "0", "off", "no" then false
               else
                 raise "Invalid power value '#{raw}', expected true|false"
               end
      controller.power(target)
      puts %({"ok":true,"command":"power","target_on":#{target}})
    when "take_photo"
      controller.take_photo
      puts %({"ok":true,"command":"take_photo"})
    else
      raise "Unknown command '#{command}'"
    end
  else
    loop do
      puts
      puts "Choose action:"
      puts "  1) status"
      puts "  2) microwave"
      puts "  3) preheat"
      puts "  4) pause"
      puts "  5) resume"
      puts "  6) stop"
      puts "  7) power"
      puts "  8) take_photo"
      puts "  q) quit"

      choice = prompt("action")
      break unless choice

      begin
        case choice
        when "1", "status"
          puts controller.status.to_json
        when "2", "microwave"
          seconds_raw = prompt("seconds") || ""
          seconds = seconds_raw.to_i
          controller.microwave(seconds)
          puts %({"ok":true,"command":"microwave","seconds":#{seconds}})
        when "3", "preheat"
          temp_raw = prompt("celsius") || ""
          celsius = temp_raw.to_i
          controller.preheat(celsius)
          puts %({"ok":true,"command":"preheat","celsius":#{celsius},"duration_seconds":3600})
        when "4", "pause"
          controller.pause
          puts %({"ok":true,"command":"pause"})
        when "5", "resume"
          controller.resume
          puts %({"ok":true,"command":"resume"})
        when "6", "stop"
          controller.stop
          puts %({"ok":true,"command":"stop"})
        when "7", "power"
          raw = prompt("target_on (true|false)") || ""
          target = case raw.downcase
                   when "true", "1", "on", "yes"  then true
                   when "false", "0", "off", "no" then false
                   else
                     raise "Invalid power value '#{raw}', expected true|false"
                   end
          controller.power(target)
          puts %({"ok":true,"command":"power","target_on":#{target}})
        when "8", "take_photo"
          controller.take_photo
          puts %({"ok":true,"command":"take_photo"})
        when "q", "quit", "exit"
          break
        else
          puts "Unknown choice: #{choice}"
        end
      rescue ex
        STDERR.puts ex.message
      end
    end
  end
rescue ex
  STDERR.puts ex.message
  exit 1
ensure
  controller.close
end
