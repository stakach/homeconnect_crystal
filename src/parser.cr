require "xml"
require "json"

require "./types"

module HomeconnectLocal
  module Parser
    # Feature map contains:
    # - feature names (refUID -> name)
    # - enumeration values (refENID -> {value -> string})
    struct FeatureMap
      getter features : Hash(Int32, String)
      getter enums : Hash(Int32, Hash(Int32, String))

      def initialize
        @features = {} of Int32 => String
        @enums = {} of Int32 => Hash(Int32, String)
      end
    end

    def self.parse_feature_mapping(xml : String) : FeatureMap
      doc = XML.parse(xml)
      fm = FeatureMap.new

      # featureDescription/feature @refUID (hex)
      doc.xpath_nodes("//featureDescription/feature").each do |node|
        ref = node["refUID"]?
        next unless ref
        uid = hex_to_i(ref)
        fm.features[uid] = (node.content || "").strip
      end

      # enumDescriptionList/enumDescription
      doc.xpath_nodes("//enumDescriptionList/enumDescription").each do |enum_node|
        enid_attr = enum_node["refENID"]?
        next unless enid_attr
        enid = hex_to_i(enid_attr)
        values = {} of Int32 => String
        enum_node.xpath_nodes("./enumMember").each do |mem|
          v = mem["refValue"]?
          next unless v
          values[v.to_i] = (mem.content || "").strip
        end
        fm.enums[enid] = values
      end

      fm
    end

    # Parse device description + feature mapping into DeviceDescription.
    def self.parse_device_description(device_xml : String, feature_xml : String) : DeviceDescription
      fm = parse_feature_mapping(feature_xml)
      doc = XML.parse(device_xml)

      dd = DeviceDescription.new

      # info
      if info_node = doc.xpath_node("//device/description")
        info = {} of String => JSON::Any
        %w[brand type model version revision].each do |k|
          if child = info_node.xpath_node("./#{k}")
            val = (child.content || "").strip
            info[k] = JSON.parse(val.to_json)
          end
        end
        dd = DeviceDescription.new(
          info: info,
          status: dd.status,
          setting: dd.setting,
          event: dd.event,
          command: dd.command,
          option: dd.option,
          program: dd.program,
          active_program: dd.active_program,
          selected_program: dd.selected_program
        )
      end

      # parse lists
      statuses = parse_entity_list(doc, fm, "//device/statusList/status")
      settings = parse_entity_list(doc, fm, "//device/settingList/setting")
      events   = parse_entity_list(doc, fm, "//device/eventList/event")
      commands = parse_entity_list(doc, fm, "//device/commandList/command")
      options  = parse_entity_list(doc, fm, "//device/optionList/option")
      programs = parse_program_list(doc, fm)

      active = parse_single_entity(doc, fm, "//device/activeProgram")
      selected = parse_single_entity(doc, fm, "//device/selectedProgram")

      DeviceDescription.new(
        info: dd.info,
        status: statuses,
        setting: settings,
        event: events,
        command: commands,
        option: options,
        program: programs,
        active_program: active,
        selected_program: selected
      )
    end

    private def self.parse_program_list(doc : XML::Node, fm : FeatureMap) : Array(EntityDesc)
      list = [] of EntityDesc
      doc.xpath_nodes("//device/programGroup/program").each do |node|
        list << parse_entity(node, fm, is_program: true)
      end
      list
    end

    private def self.parse_entity_list(doc : XML::Node, fm : FeatureMap, xpath : String) : Array(EntityDesc)
      list = [] of EntityDesc
      doc.xpath_nodes(xpath).each do |node|
        list << parse_entity(node, fm)
      end
      list
    end

    private def self.parse_single_entity(doc : XML::Node, fm : FeatureMap, xpath : String) : EntityDesc?
      if node = doc.xpath_node(xpath)
        return parse_entity(node, fm)
      end
      nil
    end

    private def self.parse_entity(node : XML::Node, fm : FeatureMap, is_program : Bool = false) : EntityDesc
      uid_hex = node["uid"]? || node["@uid"]?
      raise "missing uid" unless uid_hex
      uid = hex_to_i(uid_hex)
      name = fm.features[uid]? || "UID_#{uid}"

      protocol_type = nil
      content_type = nil
      if refcid = (node["refCID"]? || node["@refCID"]?)
        ref = hex_to_i(refcid)
        content_type = DESCRIPTION_TYPES[ref]?
        protocol_type = DESCRIPTION_PROTOCOL_TYPES[ref]?
      end

      enum_map = nil
      if enid = (node["enumerationType"]? || node["@enumerationType"]?)
        enum_map = fm.enums[hex_to_i(enid)]?
      end

      access = node["access"]? || node["@access"]?
      access_parsed = access ? Access.parse_loose(access) : nil

      available = node["available"]? || node["@available"]?
      available_parsed = available ? parse_bool(available) : nil

      min = node["min"]? || node["@min"]?
      max = node["max"]? || node["@max"]?
      step = node["stepSize"]? || node["@stepSize"]?

      options = [] of Int32
      if is_program
        node.xpath_nodes("./option").each do |opt|
          if refuid = opt["refUID"]?
            options << hex_to_i(refuid)
          end
        end
      end

      exec_str = node["execution"]? || node["@execution"]?
      exec_parsed = exec_str ? Execution.parse_loose(exec_str) : nil

      EntityDesc.new(
        uid: uid,
        name: name,
        protocol_type: protocol_type,
        content_type: content_type,
        access: access_parsed,
        available: available_parsed,
        min: min ? min.to_f64 : nil,
        max: max ? max.to_f64 : nil,
        step: step ? step.to_f64 : nil,
        enum_map: enum_map,
        options: options,
        execution: exec_parsed
      )
    end

    private def self.parse_bool(s : String) : Bool
      case s.downcase
      when "true" then true
      when "false" then false
      else
        # xml sometimes uses 0/1
        s.to_i != 0
      end
    end

    private def self.hex_to_i(s : String) : Int32
      clean = s.starts_with?("0x") ? s[2..] : s
      clean.to_i(16)
    end

    # Ported from python `homeconnect_websocket/const.py` mapping.
    # Note: we only include the handful we need for typing conversions.
    DESCRIPTION_TYPES = {
      1  => "boolean",
      2  => "integer",
      3  => "enumeration",
      4  => "float",
      5  => "string",
      16 => "timeSpan",
      17 => "percent",
      21 => "uidValue",
    }

    DESCRIPTION_PROTOCOL_TYPES = {
      1  => "Boolean",
      2  => "Integer",
      3  => "Integer",
      4  => "Float",
      5  => "String",
      16 => "Integer",
      17 => "Float",
      21 => "Integer",
    }
  end
end
