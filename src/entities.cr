require "json"

require "./types"

module HomeconnectLocal
  # A minimal transport interface for entities (so we can mock it in specs).
  module Transport
    abstract def send_sync(msg : Message, timeout : Time::Span = 15.seconds) : Message
  end

  # Converters similar to python TYPE_MAPPING.
  module TypeMapping
    def self.convert(protocol_type : String?, value : JSON::Any) : JSON::Any
      return value if protocol_type.nil?
      case protocol_type
      when "Boolean"
        # Accept true/false strings or ints
        raw = value.raw
        b = case raw
            when Bool then raw
            when Int32 then raw != 0
            when Int64 then raw != 0
            when Float64 then raw != 0.0
            when String then raw.downcase == "true" ? true : (raw.downcase == "false" ? false : raw.to_f64 != 0.0)
            else
              !!raw
            end
        JSON::Any.new(b)
      when "Integer"
        raw = value.raw
        i = case raw
            when Int32 then raw.to_i64
            when Int64 then raw
            when Float64 then raw.to_i64
            when String then raw.to_i64
            when Bool then raw ? 1_i64 : 0_i64
            else
              raw.to_s.to_i64
            end
        JSON::Any.new(i)
      when "Float"
        raw = value.raw
        f = case raw
            when Float64 then raw
            when Int32 then raw.to_f64
            when Int64 then raw.to_f64
            when String then raw.to_f64
            when Bool then raw ? 1.0 : 0.0
            else
              raw.to_s.to_f64
            end
        JSON::Any.new(f)
      when "String"
        JSON::Any.new(value.to_s)
      when "Object"
        # If the appliance sends JSON-as-string, try parse.
        raw = value.raw
        if raw.is_a?(String)
          begin
            JSON.parse(raw)
          rescue
            value
          end
        else
          value
        end
      else
        value
      end
    end
  end

  class Entity
    getter uid : Int32
    getter name : String
    getter access : Access?
    getter available : Bool?
    getter min : Float64?
    getter max : Float64?
    getter step : Float64?
    getter enum_map : Hash(Int32, String)?

    getter value_raw : JSON::Any?
    getter value_shadow_raw : JSON::Any?

    @transport : Transport
    @protocol_type : String?

    def initialize(desc : EntityDesc, @transport : Transport)
      @uid = desc.uid
      @name = desc.name
      @protocol_type = desc.protocol_type
      @enum_map = desc.enum_map
      @access = desc.access
      @available = desc.available
      @min = desc.min
      @max = desc.max
      @step = desc.step
      @value_raw = nil
      @value_shadow_raw = nil
    end

    def value : JSON::Any?
      v = @value_raw
      return nil unless v
      if em = @enum_map
        raw = v.raw
        if raw.is_a?(Int32)
          return JSON::Any.new(em[raw]? || raw)
        elsif raw.is_a?(Int64)
          return JSON::Any.new(em[raw.to_i]? || raw)
        end
      end
      v
    end

    def update_from_hash(h : Hash(String, JSON::Any))
      if v = h["value"]?
        converted = TypeMapping.convert(@protocol_type, v)
        @value_raw = converted
        @value_shadow_raw = converted
      end
      if a = h["access"]?
        @access = Access.parse_loose(a.to_s)
      end
      if av = h["available"]?
        @available = av.raw.as?(Bool) || (av.to_s.to_i != 0)
      end
      if mn = h["min"]?
        @min = mn.to_s.to_f64
      end
      if mx = h["max"]?
        @max = mx.to_s.to_f64
      end
      if st = h["stepSize"]?
        @step = st.to_s.to_f64
      end
    end

    def set_value_raw(value : JSON::Any)
      # write restrictions (best-effort)
      if @access && !{@access}.includes?(Access::READ_WRITE) && !{@access}.includes?(Access::WRITE_ONLY)
        raise ProtocolError.new("Not writable")
      end
      if @available == false
        raise ProtocolError.new("Not available")
      end

      converted = TypeMapping.convert(@protocol_type, value)
      payload = JSON.parse({"uid" => @uid, "value" => converted.raw}.to_json)
      msg = Message.new(resource: "/ro/values", action: Action::POST, data: payload)
      rsp = @transport.send_sync(msg)
      if rsp.action == Action::RESPONSE && rsp.code.nil?
        @value_shadow_raw = converted
      end
    end
  end

  class Program < Entity
    getter option_uids : Array(Int32)
    getter execution : Execution

    def initialize(desc : EntityDesc, transport : Transport)
      super(desc, transport)
      @option_uids = desc.options
      @execution = desc.execution || Execution::SELECT_AND_START
    end

    def select
      payload = JSON.parse({"program" => @uid, "options" => [] of Hash(String, JSON::Any)}.to_json)
      msg = Message.new(resource: "/ro/selectedProgram", action: Action::POST, data: payload)
      @transport.send_sync(msg)
    end

    def start(options : Hash(Int32, JSON::Any) = {} of Int32 => JSON::Any, override_options : Bool = false, entities_by_uid : Hash(Int32, Entity)? = nil)
      opts = [] of Hash(String, JSON::Any)
      options.each do |uid, v|
        opts << {"uid" => JSON::Any.new(uid), "value" => v}
      end

      if !override_options && entities_by_uid
        # include current shadow values for program options when writable and not overridden
        @option_uids.each do |ouid|
          next if options.has_key?(ouid)
          ent = entities_by_uid[ouid]?
          next unless ent
          next unless ent.access == Access::READ_WRITE
          sv = ent.value_shadow_raw
          next unless sv
          opts << {"uid" => JSON::Any.new(ouid), "value" => sv}
        end
      end

      payload = JSON.parse({"program" => @uid, "options" => opts}.to_json)
      msg = Message.new(resource: "/ro/activeProgram", action: Action::POST, data: payload)
      @transport.send_sync(msg)
    end
  end
end
