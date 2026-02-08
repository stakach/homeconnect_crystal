# examples/oven_cli.cr
#
# Interactive HomeConnect Local demo for an oven over TLS-PSK.
#
# This script:
# - connects to wss://<ip>:443/homeconnect using PSK (TLS 1.2)
# - optionally parses DeviceDescription.xml + FeatureMapping.xml to help resolve UIDs
# - lets you send common oven actions:
#     * start a preheating program at a target temperature (e.g. 180°C)
#     * pause operation (if you provide the correct uid/value for your appliance)
#     * power off (same)
#
# NOTE: Home Connect UIDs and enum values differ by appliance/profile. For reliable
# control, pass your XML files and use the prompts to select the correct entities.

require "option_parser"
require "json"

require "../src/homeconnect_local"

ip = "192.168.4.79"
psk64 = ""
identity = "homeconnect"
cipher = "PSK"

# Optional profile XML paths (helps with name->uid mapping)
device_xml_path : String? = nil
feature_xml_path : String? = nil

OptionParser.parse do |p|
  p.banner = "Usage: crystal run examples/oven_cli.cr -- [options]"
  p.on("--ip=IP", "Oven IP address (default #{ip})") { |v| ip = v }
  p.on("--psk64=KEY", "PSK in urlsafe base64 (required)") { |v| psk64 = v }
  p.on("--identity=ID", "PSK identity string (default #{identity})") { |v| identity = v }
  p.on("--cipher=CIPHER", "TLS1.2 PSK cipher string (default #{cipher})") { |v| cipher = v }
  p.on("--device-xml=PATH", "Path to DeviceDescription.xml") { |v| device_xml_path = v }
  p.on("--feature-xml=PATH", "Path to FeatureMapping.xml") { |v| feature_xml_path = v }
  p.on("-h", "--help", "Show help") { puts p; exit }
end

if psk64.empty?
  STDERR.puts "--psk64 is required"
  exit 2
end

# --- optional: parse description for lookup helpers ---
name_to_uid = {} of String => Int32
uid_to_enum = {} of Int32 => Hash(Int32, String)

if device_xml_path && feature_xml_path
  dd = HomeconnectLocal::Parser.parse_device_description(File.read(device_xml_path.not_nil!), File.read(feature_xml_path.not_nil!))

  all = dd.status + dd.setting + dd.event + dd.command + dd.option + dd.program
  all.each do |e|
    name_to_uid[e.name] = e.uid
    if em = e.enum_map
      uid_to_enum[e.uid] = em
    end
  end

  dd.active_program.try do |e|
    name_to_uid[e.name] = e.uid
    uid_to_enum[e.uid] = e.enum_map.not_nil! if e.enum_map
  end
  dd.selected_program.try do |e|
    name_to_uid[e.name] = e.uid
    uid_to_enum[e.uid] = e.enum_map.not_nil! if e.enum_map
  end

  puts "Loaded description: #{all.size} entities"
else
  puts "No XML provided; running in raw mode (you'll need UIDs/values)."
end

# --- connect ---
client = HomeconnectLocal::Client.new(
  host: ip,
  psk64: psk64,
  mode: HomeconnectLocal::TransportMode::TLS_PSK,
  psk_identity: identity,
  tls_cipher: cipher,
  app_name: "oven_cli"
)

puts "Connecting to wss://#{ip}:443/homeconnect (identity=#{identity} cipher=#{cipher})"
client.connect
puts "Connected."

# small helpers

def send_value(client : HomeconnectLocal::Client, uid : Int32, value : JSON::Any)
  msg = HomeconnectLocal::Message.new(
    resource: "/ro/values",
    action: HomeconnectLocal::Action::POST,
    data: JSON.parse({"uid" => uid, "value" => value.raw}.to_json)
  )
  client.send_sync(msg)
end

# crude name search to reduce friction

def find_first_uid(name_to_uid : Hash(String, Int32), needle : String) : Int32?
  needle_down = needle.downcase
  name_to_uid.each do |name, uid|
    return uid if name.downcase.includes?(needle_down)
  end
  nil
end

loop do
  puts
  puts "Choose action:"
  puts "  1) Start preheating to 180°C"
  puts "  2) Pause operation"
  puts "  3) Power off"
  puts "  4) Send raw /ro/values (uid + json value)"
  puts "  5) List entity names containing a substring"
  puts "  q) Quit"
  print "> "

  choice = STDIN.gets
  break unless choice
  choice = choice.strip

  case choice
  when "1"
    # These names vary. We'll try common substrings and fall back to prompting.
    # Program: often contains "PreHeating".
    program_uid = find_first_uid(name_to_uid, "preheating")

    if program_uid.nil?
      puts "Couldn't auto-find a PreHeating program."
      puts "Enter program uid (decimal or 0xHEX), or blank to cancel:"
      print "> "
      raw = STDIN.gets.try(&.strip)
      next if raw.nil? || raw.empty?
      program_uid = raw.starts_with?("0x") ? raw[2..].to_i(16) : raw.to_i
    end

    # Option for setpoint temperature often contains "SetpointTemperature".
    # Some ovens use Kelvin/°C scaling; you must confirm with your profile.
    temp_uid = find_first_uid(name_to_uid, "setpointtemperature")

    if temp_uid.nil?
      puts "Couldn't auto-find a setpoint temperature option."
      puts "Enter temperature option uid (decimal or 0xHEX), or blank to cancel:"
      print "> "
      raw = STDIN.gets.try(&.strip)
      next if raw.nil? || raw.empty?
      temp_uid = raw.starts_with?("0x") ? raw[2..].to_i(16) : raw.to_i
    end

    # Let user override temperature
    target_c = 180
    puts "Target temperature in °C? (default #{target_c})"
    print "> "
    raw_t = STDIN.gets.try(&.strip)
    target_c = raw_t.to_i if raw_t && !raw_t.empty?

    # Select program
    client.send_sync(HomeconnectLocal::Message.new(
      resource: "/ro/selectedProgram",
      action: HomeconnectLocal::Action::POST,
      data: JSON.parse({"program" => program_uid, "options" => [] of Hash(String, JSON::Any)}.to_json)
    ))

    # Start program with options
    options = [{"uid" => temp_uid, "value" => target_c}]
    client.send_sync(HomeconnectLocal::Message.new(
      resource: "/ro/activeProgram",
      action: HomeconnectLocal::Action::POST,
      data: JSON.parse({"program" => program_uid, "options" => options}.to_json)
    ))

    puts "Sent preheating start (program_uid=#{program_uid}, temp_uid=#{temp_uid}, target=#{target_c}°C)."
    puts "If nothing happens, inspect your XML and adjust the program/option UIDs and value units."

  when "2"
    puts "Pause is appliance-specific (usually an enum/state change)."
    puts "If you provided XML, try searching for e.g. 'OperationState' or 'Pause'."
    puts "Enter uid to set (decimal or 0xHEX), or blank to cancel:"
    print "> "
    raw_uid = STDIN.gets.try(&.strip)
    next if raw_uid.nil? || raw_uid.empty?
    uid = raw_uid.starts_with?("0x") ? raw_uid[2..].to_i(16) : raw_uid.to_i

    puts "Enter JSON value (e.g. 3, true, \"Pause\")"
    print "> "
    raw_val = STDIN.gets.try(&.strip)
    next if raw_val.nil? || raw_val.empty?
    val = JSON.parse(raw_val)

    send_value(client, uid.to_i, val)
    puts "Sent pause-like value set: uid=#{uid} value=#{raw_val}"

  when "3"
    puts "Power off is appliance-specific (may be a command or setting)."
    puts "Enter uid to set (decimal or 0xHEX), or blank to cancel:"
    print "> "
    raw_uid = STDIN.gets.try(&.strip)
    next if raw_uid.nil? || raw_uid.empty?
    uid = raw_uid.starts_with?("0x") ? raw_uid[2..].to_i(16) : raw_uid.to_i

    puts "Enter JSON value (common: 0 or false)"
    print "> "
    raw_val = STDIN.gets.try(&.strip)
    next if raw_val.nil? || raw_val.empty?
    val = JSON.parse(raw_val)

    send_value(client, uid.to_i, val)
    puts "Sent power-off-like value set: uid=#{uid} value=#{raw_val}"

  when "4"
    puts "uid (decimal or 0xHEX):"
    print "> "
    raw_uid = STDIN.gets.try(&.strip)
    next if raw_uid.nil? || raw_uid.empty?
    uid = raw_uid.starts_with?("0x") ? raw_uid[2..].to_i(16) : raw_uid.to_i

    puts "JSON value (e.g. 180, true, \"On\")"
    print "> "
    raw_val = STDIN.gets.try(&.strip)
    next if raw_val.nil? || raw_val.empty?
    val = JSON.parse(raw_val)

    send_value(client, uid.to_i, val)
    puts "OK"

  when "5"
    if name_to_uid.empty?
      puts "No XML loaded. Pass --device-xml and --feature-xml."
      next
    end
    puts "Substring to search:"
    print "> "
    needle = STDIN.gets.try(&.strip) || ""
    needle_down = needle.downcase

    matches = name_to_uid.keys.select { |n| n.downcase.includes?(needle_down) }.sort
    puts "Matches (#{matches.size}):"
    matches.first(100).each do |n|
      uid = name_to_uid[n]
      puts "  0x#{uid.to_s(16).rjust(8, '0')}  #{n}"
    end
    puts "(showing up to 100)"

  when "q", "quit", "exit"
    break
  else
    puts "Unknown choice"
  end
end

client.close
puts "Bye"
