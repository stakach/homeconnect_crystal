# examples/oven_cli.cr
#
# Interactive HomeConnect Local CLI for an oven over TLS-PSK.
#
# Uses DeviceDescription.xml + FeatureMapping.xml to provide:
# - status/setting/command/program discovery by name
# - value querying from /ro/allMandatoryValues and /ro/values NOTIFY
# - setting writes
# - command execution
# - program start/select with prompted options

require "option_parser"
require "json"

require "../src/homeconnect_local"

alias EntityDesc = HomeconnectLocal::EntityDesc

private def prompt(label : String) : String?
  print "#{label}> "
  STDIN.gets.try(&.strip)
end

private def parse_uid_input(input : String) : Int32?
  return nil if input.empty?
  return input[2..].to_i(16).to_i32 if input.starts_with?("0x")
  return input.to_i.to_i32 if input.matches?(/^-?\d+$/)
  nil
end

private def parse_uid_or_name(input : String, name_to_uid : Hash(String, Int32)) : Int32?
  uid = parse_uid_input(input)
  return uid if uid

  exact = name_to_uid.find { |name, _| name.downcase == input.downcase }
  return exact[1] if exact

  includes = name_to_uid.find { |name, _| name.downcase.includes?(input.downcase) }
  return includes[1] if includes

  nil
end

private def display_value(desc : EntityDesc?, raw : JSON::Any?) : String
  return "<unknown>" unless raw
  return raw.to_json unless desc

  if enum_map = desc.enum_map
    int_value = raw.as_i?
    if int_value
      label = enum_map[int_value.to_i]?
      return label ? "#{label} (#{int_value})" : int_value.to_s
    end
  end

  raw.raw.to_s
end

private def parse_enum_value(input : String, enum_map : Hash(Int32, String)) : JSON::Any
  int_val = parse_uid_input(input)
  return JSON::Any.new(int_val.to_i64) if int_val

  enum_match = enum_map.find { |_, label| label.downcase == input.downcase }
  enum_match ||= enum_map.find { |_, label| label.downcase.includes?(input.downcase) }
  if enum_match
    return JSON::Any.new(enum_match[0].to_i64)
  end

  raise "Unknown enum value '#{input}'. Try integer key or enum label substring."
end

private def parse_boolean_value(input : String) : JSON::Any
  low = input.downcase
  case low
  when "1", "true", "on", "yes"
    JSON::Any.new(true)
  when "0", "false", "off", "no"
    JSON::Any.new(false)
  else
    raise "Invalid boolean '#{input}'"
  end
end

private def parse_by_protocol(input : String, protocol : String?) : JSON::Any
  case protocol
  when "Boolean"
    parse_boolean_value(input)
  when "Integer"
    JSON::Any.new(input.to_i64)
  when "Float"
    JSON::Any.new(input.to_f64)
  when "String"
    JSON::Any.new(input)
  else
    JSON.parse(input)
  end
end

private def parse_value_for_desc(input : String, desc : EntityDesc?) : JSON::Any
  if desc && (enum_map = desc.enum_map)
    return parse_enum_value(input, enum_map)
  end

  parse_by_protocol(input, desc.try(&.protocol_type))
rescue ex
  raise "Failed to parse value '#{input}': #{ex.message}"
end

private def apply_values_payload(data : Array(JSON::Any), cache : Hash(Int32, JSON::Any))
  data.each do |entry_any|
    entry = entry_any.as_h?
    next unless entry
    uid_any = entry["uid"]?
    value_any = entry["value"]?
    next unless uid_any && value_any

    uid = uid_any.as_i?.try(&.to_i32)
    next unless uid
    cache[uid] = value_any
  end
end

private def apply_entity_payload(data : Array(JSON::Any), entities : Hash(Int32, HomeconnectLocal::Entity))
  data.each do |entry_any|
    entry = entry_any.as_h?
    next unless entry
    uid = entry["uid"]?.try(&.as_i?.try(&.to_i32))
    next unless uid
    entities[uid]?.try(&.update_from_hash(entry))
  end
end

private def refresh_values(client : HomeconnectLocal::Client, cache : Hash(Int32, JSON::Any)) : Int32
  rsp = client.send_sync(HomeconnectLocal::Message.new(resource: "/ro/allMandatoryValues", action: HomeconnectLocal::Action::GET))
  before = cache.size
  apply_values_payload(rsp.data, cache)
  cache.size - before
end

private def refresh_description_changes(client : HomeconnectLocal::Client, entities : Hash(Int32, HomeconnectLocal::Entity)) : Int32
  rsp = client.send_sync(HomeconnectLocal::Message.new(resource: "/ro/allDescriptionChanges", action: HomeconnectLocal::Action::GET))
  before_available_false = entities.values.count(&.available.==(false))
  apply_entity_payload(rsp.data, entities)
  after_available_false = entities.values.count(&.available.==(false))
  before_available_false - after_available_false
end

private def print_entities(
  list : Array(EntityDesc),
  kind : String,
  cache : Hash(Int32, JSON::Any),
)
  puts "#{kind} (#{list.size}):"
  list.each do |desc|
    val = display_value(desc, cache[desc.uid]?)
    puts "  0x#{desc.uid.to_s(16).rjust(8, '0')} #{desc.name}  value=#{val}"
  end
end

ip = "192.168.4.79"
psk64 = ""
identity = "homeconnect"
cipher = "PSK"
debug_frames = false
discover_on_start = false
discover_timeout = 2.0

device_xml_path : String? = nil
feature_xml_path : String? = nil

OptionParser.parse do |opts|
  opts.banner = "Usage: crystal run examples/oven_cli.cr -- [options]"
  opts.on("--ip=IP", "Oven IP address (default #{ip})") { |v| ip = v }
  opts.on("--psk64=KEY", "PSK in urlsafe base64 (required)") { |v| psk64 = v }
  opts.on("--identity=ID", "PSK identity string (default #{identity})") { |v| identity = v }
  opts.on("--cipher=CIPHER", "TLS1.2 PSK cipher string (default #{cipher})") { |v| cipher = v }
  opts.on("--device-xml=PATH", "Path to DeviceDescription.xml") { |v| device_xml_path = v }
  opts.on("--feature-xml=PATH", "Path to FeatureMapping.xml") { |v| feature_xml_path = v }
  opts.on("--debug-frames", "Enable websocket frame-level logging") { debug_frames = true }
  opts.on("--discover", "Discover Home Connect devices before connecting") { discover_on_start = true }
  opts.on("--discover-timeout=SECONDS", "mDNS discovery timeout in seconds (default #{discover_timeout})") { |v| discover_timeout = v.to_f }
  opts.on("-h", "--help", "Show help") { puts opts; exit }
end

if psk64.empty?
  STDERR.puts "--psk64 is required"
  exit 2
end

unless device_xml_path && feature_xml_path
  STDERR.puts "--device-xml and --feature-xml are required for this interactive CLI"
  exit 2
end

device_xml_file = device_xml_path.as(String)
feature_xml_file = feature_xml_path.as(String)

device_xml = File.read(device_xml_file)
feature_xml = File.read(feature_xml_file)
description = HomeconnectLocal::Parser.parse_device_description(device_xml, feature_xml)

status_list = description.status
setting_list = description.setting
event_list = description.event
command_list = description.command
option_list = description.option
program_list = description.program

all_entities = status_list + setting_list + event_list + command_list + option_list + program_list

uid_to_desc = {} of Int32 => EntityDesc
name_to_uid = {} of String => Int32
kind_by_uid = {} of Int32 => String

register = ->(kind : String, list : Array(EntityDesc)) do
  list.each do |desc|
    uid_to_desc[desc.uid] = desc
    name_to_uid[desc.name] = desc.uid
    kind_by_uid[desc.uid] = kind
  end
end

register.call("status", status_list)
register.call("setting", setting_list)
register.call("event", event_list)
register.call("command", command_list)
register.call("option", option_list)
register.call("program", program_list)
event_uids = event_list.map(&.uid).to_set

description.active_program.try { |desc| uid_to_desc[desc.uid] = desc; name_to_uid[desc.name] = desc.uid; kind_by_uid[desc.uid] = "activeProgram" }
description.selected_program.try { |desc| uid_to_desc[desc.uid] = desc; name_to_uid[desc.name] = desc.uid; kind_by_uid[desc.uid] = "selectedProgram" }

puts "Loaded description: #{all_entities.size} entities"
puts "  status=#{status_list.size} setting=#{setting_list.size} event=#{event_list.size} command=#{command_list.size} option=#{option_list.size} program=#{program_list.size}"

print_discovery = -> do
  puts "Discovering Home Connect devices (timeout #{discover_timeout}s)..."
  devices = HomeconnectLocal.discover_devices(timeout: discover_timeout.seconds)
  puts "Found #{devices.size} device(s)."
  devices.each_with_index do |device, idx|
    ip_list = device.ip_addresses.empty? ? "<none>" : device.ip_addresses.join(", ")
    puts "  #{idx + 1}) service=#{device.service_name} target=#{device.target_host || "<none>"} port=#{device.port || 0} ips=[#{ip_list}]"
  end
end

print_discovery.call if discover_on_start

client = HomeconnectLocal::Client.new(
  host: ip,
  psk64: psk64,
  mode: HomeconnectLocal::TransportMode::TLS_PSK,
  psk_identity: identity,
  tls_cipher: cipher,
  app_name: "oven_cli"
)
client.debug_frames = debug_frames
client.keepalive_status_from_description = description

value_cache = {} of Int32 => JSON::Any
entity_cache = {} of Int32 => HomeconnectLocal::Entity
uid_to_desc.each do |uid, desc|
  entity_cache[uid] = HomeconnectLocal::Entity.new(desc, client)
end

client.on_notify = ->(msg : HomeconnectLocal::Message) do
  if msg.resource == "/ro/values"
    before = value_cache.dup
    apply_values_payload(msg.data, value_cache)
    apply_entity_payload(msg.data, entity_cache)
    msg.data.each do |entry_any|
      entry = entry_any.as_h?
      next unless entry
      uid_any = entry["uid"]?
      value_any = entry["value"]?
      next unless uid_any && value_any
      uid = uid_any.as_i?.try(&.to_i32)
      next unless uid
      next unless event_uids.includes?(uid)

      desc = uid_to_desc[uid]?
      old_value = before[uid]?
      old_rendered = display_value(desc, old_value)
      new_rendered = display_value(desc, value_any)
      changed = old_value.nil? || old_rendered != new_rendered
      next unless changed

      name = desc.try(&.name) || "UID_#{uid}"
      puts
      puts "[EVENT] #{name} (0x#{uid.to_s(16).rjust(8, '0')}) => #{new_rendered}"
      print "> "
    end
  elsif msg.resource == "/ro/descriptionChange"
    apply_entity_payload(msg.data, entity_cache)
    puts
    puts "[NOTIFY] /ro/descriptionChange received"
    print "> "
  end
end

puts "Connecting to wss://#{ip}:443/homeconnect (identity=#{identity} cipher=#{cipher})"
client.connect
puts "Connected."

begin
  added = refresh_values(client, value_cache)
  puts "Initial values loaded: #{value_cache.size} entries (#{added} newly added)."
rescue ex
  STDERR.puts "warning: unable to refresh mandatory values: #{ex.message}"
end

begin
  made_available = refresh_description_changes(client, entity_cache)
  puts "Initial description changes loaded (entities made available: #{made_available})."
rescue ex
  STDERR.puts "warning: unable to refresh description changes: #{ex.message}"
end

loop do
  puts
  puts "Choose action:"
  puts "  1) List status"
  puts "  2) List settings"
  puts "  3) List commands"
  puts "  4) List events"
  puts "  5) List options"
  puts "  6) List programs"
  puts "  7) Search entities by name"
  puts "  8) Query one entity value"
  puts "  9) Set setting value"
  puts " 10) Set option value"
  puts " 11) Execute command"
  puts " 12) Run/select program"
  puts " 13) Refresh values from device"
  puts " 14) Discover devices (mDNS)"
  puts "  q) Quit"

  choice = prompt("")
  break unless choice

  case choice
  when "1"
    print_entities(status_list, "Status", value_cache)
  when "2"
    print_entities(setting_list, "Settings", value_cache)
  when "3"
    print_entities(command_list, "Commands", value_cache)
  when "4"
    print_entities(event_list, "Events", value_cache)
  when "5"
    print_entities(option_list, "Options", value_cache)
  when "6"
    print_entities(program_list, "Programs", value_cache)
  when "7"
    needle = prompt("Search substring")
    next unless needle

    matches = name_to_uid.keys.select(&.downcase.includes?(needle.downcase))
    matches.sort!
    puts "Matches (#{matches.size}):"
    matches.each do |name|
      uid = name_to_uid[name]
      kind = kind_by_uid[uid]? || "unknown"
      val = display_value(uid_to_desc[uid]?, value_cache[uid]?)
      puts "  [#{kind}] 0x#{uid.to_s(16).rjust(8, '0')} #{name} value=#{val}"
    end
  when "8"
    raw = prompt("Entity name or uid")
    next unless raw
    uid = parse_uid_or_name(raw, name_to_uid)
    if uid.nil?
      puts "Not found"
      next
    end

    desc = uid_to_desc[uid]?
    kind = kind_by_uid[uid]? || "unknown"
    puts "uid=0x#{uid.to_s(16).rjust(8, '0')} kind=#{kind} name=#{desc.try(&.name) || "UID_#{uid}"}"
    puts "access=#{desc.try(&.access)} available=#{desc.try(&.available)} protocol=#{desc.try(&.protocol_type)}"
    if enum_map = desc.try(&.enum_map)
      preview = enum_map.to_a.first(12).map { |pair| "#{pair[0]}=#{pair[1]}" }.join(", ")
      puts "enum: #{preview}#{enum_map.size > 12 ? ", ..." : ""}"
    end
    puts "value=#{display_value(desc, value_cache[uid]?)}"
  when "9"
    raw = prompt("Setting name or uid")
    next unless raw
    uid = parse_uid_or_name(raw, name_to_uid)
    if uid.nil?
      puts "Setting not found"
      next
    end

    desc = uid_to_desc[uid]?
    if kind_by_uid[uid]? != "setting"
      puts "UID 0x#{uid.to_s(16)} is not a setting (kind=#{kind_by_uid[uid]? || "unknown"})"
      next
    end

    puts "Selected setting: #{desc.try(&.name) || "UID_#{uid}"}"
    if enum_map = desc.try(&.enum_map)
      puts "Enum values:"
      enum_map.each do |k, v|
        puts "  #{k} => #{v}"
      end
    end

    raw_value = prompt("Value")
    next unless raw_value

    begin
      value = parse_value_for_desc(raw_value, desc)
      entity = entity_cache[uid]? || HomeconnectLocal::Entity.new(desc || raise("missing description"), client)
      entity.value_raw = value
      value_cache[uid] = value
      puts "OK: #{desc.try(&.name) || uid.to_s} <= #{display_value(desc, value)}"
    rescue ex
      puts "Set failed: #{ex.message}"
    end
  when "10"
    raw = prompt("Option name or uid")
    next unless raw
    uid = parse_uid_or_name(raw, name_to_uid)
    if uid.nil?
      puts "Option not found"
      next
    end

    desc = uid_to_desc[uid]?
    if kind_by_uid[uid]? != "option"
      puts "UID 0x#{uid.to_s(16)} is not an option (kind=#{kind_by_uid[uid]? || "unknown"})"
      next
    end

    puts "Selected option: #{desc.try(&.name) || "UID_#{uid}"}"
    if enum_map = desc.try(&.enum_map)
      puts "Enum values:"
      enum_map.each do |k, v|
        puts "  #{k} => #{v}"
      end
    end

    raw_value = prompt("Value")
    next unless raw_value

    begin
      entity = entity_cache[uid]? || HomeconnectLocal::Entity.new(desc || raise("missing description"), client)
      value = parse_value_for_desc(raw_value, desc)
      entity.value_raw = value
      value_cache[uid] = value
      puts "Option write sent: #{desc.try(&.name) || uid.to_s} <= #{display_value(desc, value)}"
    rescue ex
      puts "Option write failed: #{ex.message}"
    end
  when "11"
    raw = prompt("Command name or uid")
    next unless raw
    uid = parse_uid_or_name(raw, name_to_uid)
    if uid.nil?
      puts "Command not found"
      next
    end

    desc = uid_to_desc[uid]?
    if kind_by_uid[uid]? != "command"
      puts "UID 0x#{uid.to_s(16)} is not a command (kind=#{kind_by_uid[uid]? || "unknown"})"
      next
    end

    puts "Selected command: #{desc.try(&.name) || "UID_#{uid}"}"
    if enum_map = desc.try(&.enum_map)
      puts "Enum values:"
      enum_map.each do |k, v|
        puts "  #{k} => #{v}"
      end
    end

    default_text = desc.try(&.protocol_type) == "Boolean" ? "true" : "1"
    raw_value = prompt("Value (blank for #{default_text})") || ""
    raw_value = default_text if raw_value.empty?

    begin
      value = parse_value_for_desc(raw_value, desc)
      entity = entity_cache[uid]? || HomeconnectLocal::Entity.new(desc || raise("missing description"), client)
      entity.value_raw = value
      puts "Command sent: #{desc.try(&.name) || uid.to_s} value=#{display_value(desc, value)}"
    rescue ex
      puts "Command failed: #{ex.message}"
    end
  when "12"
    raw = prompt("Program name or uid")
    next unless raw
    uid = parse_uid_or_name(raw, name_to_uid)
    if uid.nil?
      puts "Program not found"
      next
    end

    desc = uid_to_desc[uid]?
    if kind_by_uid[uid]? != "program"
      puts "UID 0x#{uid.to_s(16)} is not a program (kind=#{kind_by_uid[uid]? || "unknown"})"
      next
    end

    program = HomeconnectLocal::Program.new(desc || raise("missing description"), client)

    puts "Selected program: #{program.name}"
    puts "Execution type: #{program.execution}"

    options = {} of Int32 => JSON::Any
    if program.option_uids.empty?
      puts "No options for this program."
    else
      puts "Enter option values (blank to skip each option)."
      program.option_uids.each do |option_uid|
        option_desc = uid_to_desc[option_uid]?
        option_name = option_desc.try(&.name) || "UID_#{option_uid}"
        current = display_value(option_desc, value_cache[option_uid]?)

        if enum_map = option_desc.try(&.enum_map)
          sample = enum_map.to_a.first(8).map { |pair| "#{pair[0]}=#{pair[1]}" }.join(", ")
          puts "  #{option_name} enum: #{sample}#{enum_map.size > 8 ? ", ..." : ""}"
        end

        raw_value = prompt("  #{option_name} (current #{current})") || ""
        next if raw_value.empty?

        begin
          options[option_uid] = parse_value_for_desc(raw_value, option_desc)
        rescue ex
          puts "  skipped #{option_name}: #{ex.message}"
        end
      end
    end

    begin
      case program.execution
      when HomeconnectLocal::Execution::SELECT_ONLY
        program.select
        puts "Program selected."
      else
        program.start(options, override_options: true)
        options.each { |k, v| value_cache[k] = v }
        puts "Program start sent with: #{options}"
      end
    rescue ex
      puts "Program action failed: #{ex.message}"
    end
  when "13"
    begin
      added = refresh_values(client, value_cache)
      puts "Refreshed values: #{value_cache.size} entries (#{added} newly added)."
    rescue ex
      puts "Refresh failed: #{ex.message}"
    end
  when "14"
    print_discovery.call
  when "q", "quit", "exit"
    break
  else
    puts "Unknown choice"
  end
end

client.close
puts "Bye"
