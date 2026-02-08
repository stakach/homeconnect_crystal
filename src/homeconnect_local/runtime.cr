require "json"
require "set"

require "./entities"

module HomeconnectLocal
  module Runtime
    class Error < Exception; end

    class NotStarted < Error; end

    class UnknownService < Error; end

    class UnknownEntity < Error; end

    class InvalidServicePayload < Error; end

    struct EntityState
      getter state : String
      getter attributes : Hash(String, JSON::Any)

      def initialize(
        @state : String = "unknown",
        @attributes : Hash(String, JSON::Any) = {} of String => JSON::Any,
      )
      end
    end

    class StateStore
      @states = {} of String => EntityState

      def update(entity_id : String, state : EntityState)
        @states[entity_id] = state
      end

      def get(entity_id : String) : EntityState?
        @states[entity_id]?
      end
    end

    alias ServiceHandler = Proc(Hash(String, JSON::Any), Nil)

    class ServiceBus
      @handlers = {} of String => ServiceHandler

      def register(domain : String, service : String, &block : Hash(String, JSON::Any) -> Nil)
        @handlers[key(domain, service)] = block
      end

      def call(domain : String, service : String, data : Hash(String, JSON::Any))
        handler = @handlers[key(domain, service)]? || raise UnknownService.new("#{domain}.#{service}")
        handler.call(data)
      end

      private def key(domain : String, service : String) : String
        "#{domain}.#{service}"
      end
    end

    abstract class IntegrationEntity
      getter entity_id : String
      getter uids : Array(Int32)

      def initialize(
        @entity_id : String,
        @uids : Array(Int32),
      )
      end

      abstract def domain : String
      abstract def to_state : EntityState
      abstract def handle_service(service : String, data : Hash(String, JSON::Any))

      def apply_value_payload(_payload : Hash(String, JSON::Any))
      end
    end

    module EntityValueHelpers
      def self.effective_raw(entity : Entity)
        entity.value_raw.try(&.raw) || entity.value_shadow_raw.try(&.raw)
      end

      def self.to_i(raw) : Int32?
        case raw
        when Int32
          raw
        when Int64
          raw.to_i32
        when Float64
          raw.to_i
        when String
          raw.to_i?
        else
          nil
        end
      end

      def self.to_bool(raw) : Bool?
        case raw
        when Bool
          raw
        when Int32
          raw != 0
        when Int64
          raw != 0
        when String
          return true if raw.downcase == "true" || raw == "1"
          return false if raw.downcase == "false" || raw == "0"
          nil
        else
          nil
        end
      end
    end

    class SwitchEntity < IntegrationEntity
      @entity : Entity
      @value_mapping : Tuple(JSON::Any, JSON::Any)?

      def initialize(
        @entity : Entity,
        entity_id : String,
        @friendly_name : String,
        @value_mapping : Tuple(JSON::Any, JSON::Any)? = nil,
      )
        super(entity_id, [@entity.uid])
      end

      def domain : String
        "switch"
      end

      def to_state : EntityState
        raw = EntityValueHelpers.effective_raw(@entity)
        bool = EntityValueHelpers.to_bool(raw)
        state = if !bool.nil?
                  bool ? "on" : "off"
                elsif i = EntityValueHelpers.to_i(raw)
                  mapped_switch_state(i)
                elsif raw.is_a?(String)
                  raw.downcase == "on" ? "on" : "off"
                else
                  "unknown"
                end

        EntityState.new(
          state: state,
          attributes: {"friendly_name" => JSON::Any.new(@friendly_name)}
        )
      end

      def handle_service(service : String, data : Hash(String, JSON::Any))
        _ = data
        case service
        when "turn_on"
          @entity.value_raw = on_value
        when "turn_off"
          @entity.value_raw = off_value
        else
          raise UnknownService.new("#{domain}.#{service}")
        end
      end

      def apply_value_payload(payload : Hash(String, JSON::Any))
        @entity.update_from_hash(payload)
      end

      private def on_value : JSON::Any
        mapping = @value_mapping
        return JSON::Any.new(true) unless mapping
        mapping[0]
      end

      private def off_value : JSON::Any
        mapping = @value_mapping
        return JSON::Any.new(false) unless mapping
        mapping[1]
      end

      private def mapped_switch_state(v : Int32) : String
        mapping = @value_mapping
        return "unknown" unless mapping
        on_v = EntityValueHelpers.to_i(mapping[0].raw)
        off_v = EntityValueHelpers.to_i(mapping[1].raw)
        return "on" if on_v == v
        return "off" if off_v == v
        "unknown"
      end
    end

    class BinarySensorEntity < IntegrationEntity
      @entity : Entity
      @value_on : Set(String)?
      @value_off : Set(String)?

      def initialize(
        @entity : Entity,
        entity_id : String,
        @friendly_name : String,
        value_on : Enumerable(String)? = nil,
        value_off : Enumerable(String)? = nil,
      )
        super(entity_id, [@entity.uid])
        @value_on = value_on ? value_on.to_set : nil
        @value_off = value_off ? value_off.to_set : nil
      end

      def domain : String
        "binary_sensor"
      end

      def to_state : EntityState
        raw = EntityValueHelpers.effective_raw(@entity)
        bool = EntityValueHelpers.to_bool(raw)
        state = if !bool.nil?
                  bool ? "on" : "off"
                else
                  str = raw ? raw.to_s : ""
                  if set = @value_on
                    set.includes?(str) ? "on" : (@value_off.try(&.includes?(str)) ? "off" : "unknown")
                  elsif set = @value_off
                    set.includes?(str) ? "off" : "unknown"
                  else
                    "unknown"
                  end
                end

        EntityState.new(
          state: state,
          attributes: {"friendly_name" => JSON::Any.new(@friendly_name)}
        )
      end

      def handle_service(service : String, data : Hash(String, JSON::Any))
        _ = data
        raise UnknownService.new("#{domain}.#{service}")
      end

      def apply_value_payload(payload : Hash(String, JSON::Any))
        @entity.update_from_hash(payload)
      end
    end

    class SensorEntity < IntegrationEntity
      @entity : Entity
      @value_to_label : Hash(String, String)?
      @options : Array(String)?

      def initialize(
        @entity : Entity,
        entity_id : String,
        @friendly_name : String,
        @value_to_label : Hash(String, String)? = nil,
        @options : Array(String)? = nil,
      )
        super(entity_id, [@entity.uid])
      end

      def domain : String
        "sensor"
      end

      def to_state : EntityState
        raw = EntityValueHelpers.effective_raw(@entity)
        state = if raw.nil?
                  "unknown"
                elsif mapping = @value_to_label
                  mapping[raw.to_s]? || raw.to_s
                elsif v = @entity.value
                  v.raw.to_s
                else
                  raw.to_s
                end

        attrs = {"friendly_name" => JSON::Any.new(@friendly_name)} of String => JSON::Any
        if options = @options
          attrs["options"] = JSON::Any.new(options.map { |opt| JSON::Any.new(opt) })
        end

        EntityState.new(state: state, attributes: attrs)
      end

      def handle_service(service : String, data : Hash(String, JSON::Any))
        _ = data
        raise UnknownService.new("#{domain}.#{service}")
      end

      def apply_value_payload(payload : Hash(String, JSON::Any))
        @entity.update_from_hash(payload)
      end
    end

    class SelectEntity < IntegrationEntity
      @entity : Entity
      @option_to_value : Hash(String, JSON::Any)
      @value_to_option : Hash(String, String)

      def initialize(
        @entity : Entity,
        entity_id : String,
        @friendly_name : String,
        @option_to_value : Hash(String, JSON::Any),
      )
        super(entity_id, [@entity.uid])
        @value_to_option = {} of String => String
        @option_to_value.each do |option, value|
          @value_to_option[value.raw.to_s] = option
        end
      end

      def domain : String
        "select"
      end

      def to_state : EntityState
        raw = EntityValueHelpers.effective_raw(@entity)
        state = raw ? (@value_to_option[raw.to_s]? || "unknown") : "unknown"
        options = @option_to_value.keys.map { |v| JSON::Any.new(v) }
        EntityState.new(
          state: state,
          attributes: {
            "friendly_name" => JSON::Any.new(@friendly_name),
            "options"       => JSON::Any.new(options),
          }
        )
      end

      def handle_service(service : String, data : Hash(String, JSON::Any))
        case service
        when "select_option"
          option = data["option"]?.try(&.as_s) || raise InvalidServicePayload.new("Missing option")
          value = @option_to_value[option]? || raise InvalidServicePayload.new("Unknown option #{option}")
          @entity.value_raw = value
        else
          raise UnknownService.new("#{domain}.#{service}")
        end
      end

      def apply_value_payload(payload : Hash(String, JSON::Any))
        @entity.update_from_hash(payload)
      end
    end

    class NumberEntity < IntegrationEntity
      @entity : Entity

      def initialize(
        @entity : Entity,
        entity_id : String,
        @friendly_name : String,
      )
        super(entity_id, [@entity.uid])
      end

      def domain : String
        "number"
      end

      def to_state : EntityState
        raw = EntityValueHelpers.effective_raw(@entity)
        state = raw ? raw.to_s : "unknown"
        attrs = {
          "friendly_name" => JSON::Any.new(@friendly_name),
        } of String => JSON::Any
        if min = @entity.min
          attrs["min"] = JSON::Any.new(min)
        end
        if max = @entity.max
          attrs["max"] = JSON::Any.new(max)
        end
        if step = @entity.step
          attrs["step"] = JSON::Any.new(step)
        end
        EntityState.new(state: state, attributes: attrs)
      end

      def handle_service(service : String, data : Hash(String, JSON::Any))
        case service
        when "set_value"
          value = data["value"]? || raise InvalidServicePayload.new("Missing value")
          @entity.value_raw = value
        else
          raise UnknownService.new("#{domain}.#{service}")
        end
      end

      def apply_value_payload(payload : Hash(String, JSON::Any))
        @entity.update_from_hash(payload)
      end
    end

    class FanEntity < IntegrationEntity
      @transport : Transport
      @speed1 : Entity
      @speed2 : Entity

      def initialize(
        @transport : Transport,
        @speed1 : Entity,
        @speed2 : Entity,
        entity_id : String,
        @friendly_name : String,
      )
        super(entity_id, [@speed1.uid, @speed2.uid])
      end

      def domain : String
        "fan"
      end

      def to_state : EntityState
        pct = current_percentage
        state = pct > 0 ? "on" : "off"
        EntityState.new(
          state: state,
          attributes: {
            "friendly_name"   => JSON::Any.new(@friendly_name),
            "percentage"      => JSON::Any.new(pct),
            "percentage_step" => JSON::Any.new(25),
          }
        )
      end

      def handle_service(service : String, data : Hash(String, JSON::Any))
        case service
        when "set_percentage"
          pct = data["percentage"]?.try(&.as_i) || raise InvalidServicePayload.new("Missing percentage")
          send_percentage(pct)
        else
          raise UnknownService.new("#{domain}.#{service}")
        end
      end

      def apply_value_payload(payload : Hash(String, JSON::Any))
        uid = payload["uid"]?.try(&.as_i?)
        return unless uid
        if uid == @speed1.uid
          @speed1.update_from_hash(payload)
        elsif uid == @speed2.uid
          @speed2.update_from_hash(payload)
        end
      end

      private def current_percentage : Int32
        s1 = EntityValueHelpers.to_i(EntityValueHelpers.effective_raw(@speed1)) || 0
        s2 = EntityValueHelpers.to_i(EntityValueHelpers.effective_raw(@speed2)) || 0
        return 25 if s1 == 1
        return 50 if s1 == 2
        return 75 if s2 == 1
        return 100 if s2 == 2
        0
      end

      private def send_percentage(pct : Int32)
        s1, s2 = case pct
                 when 25
                   {1, 0}
                 when 50
                   {2, 0}
                 when 75
                   {0, 1}
                 when 100
                   {0, 2}
                 else
                   {0, 0}
                 end

        entries = [
          {"uid" => JSON::Any.new(@speed1.uid), "value" => JSON::Any.new(s1)},
          {"uid" => JSON::Any.new(@speed2.uid), "value" => JSON::Any.new(s2)},
        ]
        Runtime.send_values(@transport, entries)
        @speed1.update_from_hash({"value" => JSON::Any.new(s1)})
        @speed2.update_from_hash({"value" => JSON::Any.new(s2)})
      end
    end

    class ButtonEntity < IntegrationEntity
      @entity : Entity
      @press_value : JSON::Any

      def initialize(
        @entity : Entity,
        entity_id : String,
        @friendly_name : String,
        @press_value : JSON::Any = JSON::Any.new(true),
      )
        super(entity_id, [@entity.uid])
      end

      def domain : String
        "button"
      end

      def to_state : EntityState
        EntityState.new(
          state: "unknown",
          attributes: {"friendly_name" => JSON::Any.new(@friendly_name)}
        )
      end

      def handle_service(service : String, data : Hash(String, JSON::Any))
        _ = data
        case service
        when "press"
          @entity.value_raw = @press_value
        else
          raise UnknownService.new("#{domain}.#{service}")
        end
      end

      def apply_value_payload(payload : Hash(String, JSON::Any))
        @entity.update_from_hash(payload)
      end
    end

    class StartProgramButtonEntity < IntegrationEntity
      @selected_program : Entity
      @programs_by_uid : Hash(Int32, Program)

      def initialize(
        @selected_program : Entity,
        @programs_by_uid : Hash(Int32, Program),
        entity_id : String,
        @friendly_name : String,
      )
        super(entity_id, [@selected_program.uid])
      end

      def domain : String
        "button"
      end

      def to_state : EntityState
        EntityState.new(
          state: "unknown",
          attributes: {"friendly_name" => JSON::Any.new(@friendly_name)}
        )
      end

      def handle_service(service : String, data : Hash(String, JSON::Any))
        _ = data
        raise UnknownService.new("#{domain}.#{service}") unless service == "press"

        selected = EntityValueHelpers.to_i(EntityValueHelpers.effective_raw(@selected_program))
        raise InvalidServicePayload.new("No selected program") unless selected
        program = @programs_by_uid[selected]? || raise InvalidServicePayload.new("Unknown program #{selected}")
        options = {} of Int32 => JSON::Any
        program.option_uids.each do |uid|
          options[uid] = JSON::Any.new(nil)
        end
        program.start(options, override_options: true)
      end

      def apply_value_payload(payload : Hash(String, JSON::Any))
        @selected_program.update_from_hash(payload)
      end
    end

    class LightEntity < IntegrationEntity
      DEFAULT_MIN_K = 2000
      DEFAULT_MAX_K = 6534

      @transport : Transport
      @power : Entity
      @brightness : Entity?
      @color_temp_percent : Entity?
      @rgb_hex : Entity?
      @color_mode : Entity?
      @invert_color_temp : Bool

      def initialize(
        @transport : Transport,
        @power : Entity,
        entity_id : String,
        @friendly_name : String,
        @brightness : Entity? = nil,
        @color_temp_percent : Entity? = nil,
        @rgb_hex : Entity? = nil,
        @color_mode : Entity? = nil,
        @invert_color_temp : Bool = false,
      )
        uids = [@power.uid]
        if brightness = @brightness
          uids << brightness.uid
        end
        if color_temp_percent = @color_temp_percent
          uids << color_temp_percent.uid
        end
        if rgb_hex = @rgb_hex
          uids << rgb_hex.uid
        end
        if color_mode = @color_mode
          uids << color_mode.uid
        end
        super(entity_id, uids)
      end

      def domain : String
        "light"
      end

      def to_state : EntityState
        attrs = {
          "friendly_name"         => JSON::Any.new(@friendly_name),
          "color_mode"            => JSON::Any.new(color_mode),
          "supported_color_modes" => JSON::Any.new([JSON::Any.new(color_mode)]),
        } of String => JSON::Any

        if rgb = current_rgb
          attrs["rgb_color"] = JSON::Any.new([JSON::Any.new(rgb[0]), JSON::Any.new(rgb[1]), JSON::Any.new(rgb[2])])
          attrs["brightness"] = JSON::Any.new(rgb[3])
        elsif brightness = @brightness
          if percent = EntityValueHelpers.to_i(EntityValueHelpers.effective_raw(brightness))
            attrs["brightness"] = JSON::Any.new(percent_to_255(percent))
          end
        end

        if ct = @color_temp_percent
          if pct = EntityValueHelpers.to_i(EntityValueHelpers.effective_raw(ct))
            attrs["color_temp_kelvin"] = JSON::Any.new(percent_to_kelvin(pct))
          end
        end

        state = light_on? ? "on" : "off"
        EntityState.new(state: state, attributes: attrs)
      end

      # ameba:disable Metrics/CyclomaticComplexity
      def handle_service(service : String, data : Hash(String, JSON::Any))
        raise UnknownService.new("#{domain}.#{service}") unless service == "turn_on"

        entries = [] of Hash(String, JSON::Any)

        if rgb = data["rgb_color"]?
          rgb_hex = @rgb_hex || raise InvalidServicePayload.new("RGB entity is required for rgb_color")
          entries << {"uid" => JSON::Any.new(rgb_hex.uid), "value" => JSON::Any.new(rgb_to_hex(rgb, data))}
          if mode = @color_mode
            current_mode = EntityValueHelpers.to_i(EntityValueHelpers.effective_raw(mode)) || 1
            if current_mode != 1
              entries << {"uid" => JSON::Any.new(mode.uid), "value" => JSON::Any.new(1)}
            end
          end
        elsif @rgb_hex && (data["brightness"]? || data["brightness_pct"]?)
          rgb_hex = @rgb_hex || raise InvalidServicePayload.new("RGB entity is required for brightness-only RGB")
          entries << {"uid" => JSON::Any.new(rgb_hex.uid), "value" => JSON::Any.new(adjust_current_rgb_brightness(data))}
          if mode = @color_mode
            current_mode = EntityValueHelpers.to_i(EntityValueHelpers.effective_raw(mode)) || 1
            if current_mode != 1
              entries << {"uid" => JSON::Any.new(mode.uid), "value" => JSON::Any.new(1)}
            end
          end
        end

        if brightness = @brightness
          if pct_any = data["brightness_pct"]?
            pct = pct_any.as_i
            pct = 2 if pct > 0 && pct < 2
            entries << {"uid" => JSON::Any.new(brightness.uid), "value" => JSON::Any.new(pct)}
          end
        end

        if ct = @color_temp_percent
          if k_any = data["color_temp_kelvin"]?
            entries << {"uid" => JSON::Any.new(ct.uid), "value" => JSON::Any.new(kelvin_to_percent(k_any.as_i))}
          end
        end

        if entries.empty?
          entries << {"uid" => JSON::Any.new(@power.uid), "value" => JSON::Any.new(true)}
        elsif !light_on?
          entries << {"uid" => JSON::Any.new(@power.uid), "value" => JSON::Any.new(true)}
        end

        Runtime.send_values(@transport, entries)
        apply_entries(entries)
      end

      # ameba:enable Metrics/CyclomaticComplexity

      def apply_value_payload(payload : Hash(String, JSON::Any))
        uid = payload["uid"]?.try(&.as_i?)
        return unless uid
        case uid
        when @power.uid
          @power.update_from_hash(payload)
        when @brightness.try(&.uid)
          @brightness.try(&.update_from_hash(payload))
        when @color_temp_percent.try(&.uid)
          @color_temp_percent.try(&.update_from_hash(payload))
        when @rgb_hex.try(&.uid)
          @rgb_hex.try(&.update_from_hash(payload))
        when @color_mode.try(&.uid)
          @color_mode.try(&.update_from_hash(payload))
        end
      end

      private def apply_entries(entries : Array(Hash(String, JSON::Any)))
        entries.each do |entry|
          apply_value_payload(entry)
        end
      end

      private def color_mode : String
        return "rgb" if @rgb_hex
        return "color_temp" if @color_temp_percent
        return "brightness" if @brightness
        "onoff"
      end

      private def light_on? : Bool
        EntityValueHelpers.to_bool(EntityValueHelpers.effective_raw(@power)) || false
      end

      private def percent_to_255(percent : Int32) : Int32
        ((255.0 * percent / 100.0).round).to_i
      end

      private def percent_to_kelvin(percent : Int32) : Int32
        pct = @invert_color_temp ? (100 - percent) : percent
        (DEFAULT_MIN_K + ((DEFAULT_MAX_K - DEFAULT_MIN_K) * (pct / 100.0))).round.to_i
      end

      private def kelvin_to_percent(kelvin : Int32) : Int32
        k = kelvin.clamp(DEFAULT_MIN_K, DEFAULT_MAX_K)
        pct = ((k - DEFAULT_MIN_K) * 100.0 / (DEFAULT_MAX_K - DEFAULT_MIN_K)).round.to_i
        @invert_color_temp ? (100 - pct) : pct
      end

      private def current_rgb
        entity = @rgb_hex
        return nil unless entity
        raw = EntityValueHelpers.effective_raw(entity)
        return nil unless raw.is_a?(String)
        parse_hex_color(raw)
      end

      private def parse_hex_color(raw : String)
        return nil unless raw.starts_with?("#") && raw.size == 7
        r = raw[1, 2].to_i(16)
        g = raw[3, 2].to_i(16)
        b = raw[5, 2].to_i(16)
        max = {r, g, b}.max
        return {0, 0, 0, 0} if max == 0
        scale = 255.0 / max
        {(r * scale).round.to_i, (g * scale).round.to_i, (b * scale).round.to_i, max}
      end

      private def rgb_to_hex(rgb_any : JSON::Any, data : Hash(String, JSON::Any)) : String
        arr = rgb_any.as_a
        r = arr[0].as_i
        g = arr[1].as_i
        b = arr[2].as_i

        if pct_any = data["brightness_pct"]?
          scale = pct_any.as_i.clamp(0, 100) / 100.0
          r = (r * scale).round.to_i
          g = (g * scale).round.to_i
          b = (b * scale).round.to_i
        elsif bri_any = data["brightness"]?
          scale = bri_any.as_i.clamp(0, 255) / 255.0
          r = (r * scale).round.to_i
          g = (g * scale).round.to_i
          b = (b * scale).round.to_i
        elsif current = current_rgb
          current_brightness = current[3]
          max = {r, g, b}.max
          if max > 0
            scale = current_brightness / max.to_f
            r = (r * scale).round.to_i
            g = (g * scale).round.to_i
            b = (b * scale).round.to_i
          end
        end

        "#%02x%02x%02x" % {r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255)}
      end

      private def adjust_current_rgb_brightness(data : Hash(String, JSON::Any)) : String
        current = current_rgb || {255, 0, 0, 255}
        target = if pct_any = data["brightness_pct"]?
                   ((pct_any.as_i.clamp(0, 100) / 100.0) * 255).round.to_i
                 elsif bri_any = data["brightness"]?
                   bri_any.as_i.clamp(0, 255)
                 else
                   current[3]
                 end
        scale = target / 255.0
        r = (current[0] * scale).round.to_i
        g = (current[1] * scale).round.to_i
        b = (current[2] * scale).round.to_i
        "#%02x%02x%02x" % {r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255)}
      end
    end

    class RuntimeApp
      getter state_store : StateStore
      getter service_bus : ServiceBus
      getter? started : Bool

      @entities_by_id = {} of String => IntegrationEntity
      @entities_by_uid = {} of Int32 => Array(IntegrationEntity)

      def initialize
        @state_store = StateStore.new
        @service_bus = ServiceBus.new
        @started = false
      end

      def start
        register_default_services
        @started = true
      end

      def stop
        @started = false
      end

      def register_entity(entity : IntegrationEntity)
        @entities_by_id[entity.entity_id] = entity
        entity.uids.each do |uid|
          @entities_by_uid[uid] ||= [] of IntegrationEntity
          @entities_by_uid[uid] << entity
        end
        @state_store.update(entity.entity_id, entity.to_state)
      end

      def call_service(domain : String, service : String, data : Hash(String, JSON::Any))
        raise NotStarted.new unless @started
        @service_bus.call(domain, service, data)
      end

      def handle_values_notify(data : JSON::Any)
        entries = payload_entries(data)
        entries.each do |entry|
          uid = entry["uid"]?.try(&.as_i)
          next unless uid
          listeners = @entities_by_uid[uid.to_i32]?
          next unless listeners
          listeners.each do |entity|
            entity.apply_value_payload(entry)
            @state_store.update(entity.entity_id, entity.to_state)
          end
        end
      end

      private def payload_entries(data : JSON::Any) : Array(Hash(String, JSON::Any))
        if arr = data.as_a?
          arr.map(&.as_h)
        else
          [data.as_h]
        end
      end

      private def register_default_services
        @service_bus.register("switch", "turn_on") { |data| dispatch("switch", "turn_on", data) }
        @service_bus.register("switch", "turn_off") { |data| dispatch("switch", "turn_off", data) }
        @service_bus.register("select", "select_option") { |data| dispatch("select", "select_option", data) }
        @service_bus.register("number", "set_value") { |data| dispatch("number", "set_value", data) }
        @service_bus.register("fan", "set_percentage") { |data| dispatch("fan", "set_percentage", data) }
        @service_bus.register("light", "turn_on") { |data| dispatch("light", "turn_on", data) }
        @service_bus.register("button", "press") { |data| dispatch("button", "press", data) }
      end

      private def dispatch(domain : String, service : String, data : Hash(String, JSON::Any))
        entity_id = data["entity_id"]?.try(&.as_s) || raise InvalidServicePayload.new("Missing entity_id")
        entity = @entities_by_id[entity_id]? || raise UnknownEntity.new(entity_id)
        raise UnknownService.new("#{domain}.#{service}") unless entity.domain == domain
        entity.handle_service(service, data)
        @state_store.update(entity.entity_id, entity.to_state)
      end
    end

    def self.send_values(transport : Transport, entries : Array(Hash(String, JSON::Any)))
      msg = Message.new(
        resource: "/ro/values",
        action: Action::POST,
        data: JSON.parse(entries.to_json).as_a
      )
      transport.send_sync(msg)
    end
  end
end
