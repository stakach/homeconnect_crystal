require "./runtime"

module HomeconnectLocal
  module Runtime
    module Builder
      struct BuildConfig
        getter name_prefix : String
        getter? create_start_button : Bool
        getter start_button_name : String

        def initialize(
          @name_prefix : String = "homeconnect",
          @create_start_button : Bool = true,
          @start_button_name : String = "StartProgram",
        )
        end
      end

      # Build and start a runtime app from parsed device description.
      #
      # This constructs a practical default mapping:
      # - settings -> switch/select/number
      # - status/events -> sensor/binary_sensor
      # - commands -> button
      # - selected/active program -> select/sensor
      # - optional start-program button
      def self.from_device_description(
        device : DeviceDescription,
        transport : Transport,
        app : RuntimeApp = RuntimeApp.new,
        config : BuildConfig = BuildConfig.new,
      ) : RuntimeApp
        option_entities = {} of Int32 => Entity
        program_entities = {} of Int32 => Program
        selected_program_entity : Entity? = nil

        device.setting.each do |desc|
          ent = Entity.new(desc, transport)
          option_entities[desc.uid] = ent
          case
          when number_desc?(desc)
            app.register_entity(
              NumberEntity.new(
                ent,
                entity_id: entity_id_for("number", config.name_prefix, desc.name),
                friendly_name: friendly_name(config.name_prefix, desc.name)
              )
            )
          when select_desc?(desc)
            mapping = select_mapping(desc)
            app.register_entity(
              SelectEntity.new(
                ent,
                entity_id: entity_id_for("select", config.name_prefix, desc.name),
                friendly_name: friendly_name(config.name_prefix, desc.name),
                option_to_value: mapping
              )
            )
          when switch_desc?(desc)
            app.register_entity(
              SwitchEntity.new(
                ent,
                entity_id: entity_id_for("switch", config.name_prefix, desc.name),
                friendly_name: friendly_name(config.name_prefix, desc.name),
                value_mapping: switch_value_mapping(desc)
              )
            )
          end
        end

        device.status.each do |desc|
          ent = Entity.new(desc, transport)
          if binary_desc?(desc)
            value_on, value_off = binary_sets(desc)
            app.register_entity(
              BinarySensorEntity.new(
                ent,
                entity_id: entity_id_for("binary_sensor", config.name_prefix, desc.name),
                friendly_name: friendly_name(config.name_prefix, desc.name),
                value_on: value_on,
                value_off: value_off
              )
            )
          else
            app.register_entity(
              SensorEntity.new(
                ent,
                entity_id: entity_id_for("sensor", config.name_prefix, desc.name),
                friendly_name: friendly_name(config.name_prefix, desc.name),
                options: enum_options(desc)
              )
            )
          end
        end

        device.event.each do |desc|
          ent = Entity.new(desc, transport)
          app.register_entity(
            SensorEntity.new(
              ent,
              entity_id: entity_id_for("sensor", config.name_prefix, desc.name),
              friendly_name: friendly_name(config.name_prefix, desc.name),
              options: enum_options(desc)
            )
          )
        end

        device.command.each do |desc|
          ent = Entity.new(desc, transport)
          app.register_entity(
            ButtonEntity.new(
              ent,
              entity_id: entity_id_for("button", config.name_prefix, desc.name),
              friendly_name: friendly_name(config.name_prefix, desc.name)
            )
          )
        end

        device.program.each do |desc|
          program_entities[desc.uid] = Program.new(desc, transport)
        end

        if selected_desc = device.selected_program
          selected_program_entity = Entity.new(selected_desc, transport)
          app.register_entity(
            SelectEntity.new(
              selected_program_entity,
              entity_id: entity_id_for("select", config.name_prefix, selected_desc.name),
              friendly_name: friendly_name(config.name_prefix, selected_desc.name),
              option_to_value: program_select_mapping(device.program)
            )
          )
        end

        if active_desc = device.active_program
          active_entity = Entity.new(active_desc, transport)
          app.register_entity(
            SensorEntity.new(
              active_entity,
              entity_id: entity_id_for("sensor", config.name_prefix, active_desc.name),
              friendly_name: friendly_name(config.name_prefix, active_desc.name),
              value_to_label: program_sensor_mapping(device.program),
              options: program_option_labels(device.program)
            )
          )
        end

        if config.create_start_button? && (selected_program = selected_program_entity) && !program_entities.empty?
          app.register_entity(
            StartProgramButtonEntity.new(
              selected_program,
              program_entities,
              entity_id: entity_id_for("button", config.name_prefix, config.start_button_name),
              friendly_name: "#{config.name_prefix} #{config.start_button_name}"
            )
          )
        end

        app.start unless app.started?
        app
      end

      def self.entity_id_for(domain : String, name_prefix : String, name : String) : String
        "#{domain}.#{slug(name_prefix)}_#{slug(name)}"
      end

      private def self.friendly_name(prefix : String, name : String) : String
        "#{prefix} #{name}"
      end

      private def self.slug(s : String) : String
        s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_+|_+$/, "")
      end

      private def self.number_desc?(desc : EntityDesc) : Bool
        !!(desc.min || desc.max || desc.step)
      end

      private def self.select_desc?(desc : EntityDesc) : Bool
        if emap = desc.enum_map
          emap.size > 2
        else
          false
        end
      end

      private def self.switch_desc?(desc : EntityDesc) : Bool
        return true if desc.protocol_type == "Boolean"
        if emap = desc.enum_map
          emap.size == 2 && !!switch_value_mapping(desc)
        else
          false
        end
      end

      private def self.binary_desc?(desc : EntityDesc) : Bool
        return true if desc.protocol_type == "Boolean"
        if emap = desc.enum_map
          emap.size == 2
        else
          false
        end
      end

      private def self.select_mapping(desc : EntityDesc) : Hash(String, JSON::Any)
        out = {} of String => JSON::Any
        if emap = desc.enum_map
          emap.each do |k, v|
            out[v] = JSON::Any.new(k.to_i64)
          end
        end
        out
      end

      private def self.switch_value_mapping(desc : EntityDesc) : Tuple(JSON::Any, JSON::Any)?
        return nil if desc.protocol_type == "Boolean"
        emap = desc.enum_map
        return nil if emap.nil? || emap.size != 2
        on_key = detect_on_key(emap)
        off_key = detect_off_key(emap)
        return nil unless on_key && off_key
        {JSON::Any.new(on_key.to_i64), JSON::Any.new(off_key.to_i64)}
      end

      private def self.binary_sets(desc : EntityDesc) : {Enumerable(String)?, Enumerable(String)?}
        emap = desc.enum_map
        return {nil, nil} if emap.nil?
        on_key = detect_on_key(emap)
        off_key = detect_off_key(emap)
        return {nil, nil} unless on_key && off_key
        on_label = emap[on_key]? || on_key.to_s
        off_label = emap[off_key]? || off_key.to_s
        {Set{on_key.to_s, on_label}, Set{off_key.to_s, off_label}}
      end

      private def self.detect_on_key(values_map : Hash(Int32, String)) : Int32?
        values_map.each do |k, v|
          val = v.downcase
          return k if {"on", "standby", "true"}.includes?(val)
        end
        values_map.keys.max?
      end

      private def self.detect_off_key(values_map : Hash(Int32, String)) : Int32?
        values_map.each do |k, v|
          val = v.downcase
          return k if {"off", "mainsoff", "false"}.includes?(val)
        end
        values_map.keys.min?
      end

      private def self.enum_options(desc : EntityDesc) : Array(String)?
        if emap = desc.enum_map
          emap.values
        else
          nil
        end
      end

      private def self.program_select_mapping(programs : Array(EntityDesc)) : Hash(String, JSON::Any)
        out = {} of String => JSON::Any
        programs.each do |program_desc|
          out[program_desc.name] = JSON::Any.new(program_desc.uid.to_i64)
        end
        out
      end

      private def self.program_sensor_mapping(programs : Array(EntityDesc)) : Hash(String, String)
        out = {} of String => String
        programs.each do |program_desc|
          out[program_desc.uid.to_s] = program_desc.name
        end
        out
      end

      private def self.program_option_labels(programs : Array(EntityDesc)) : Array(String)
        programs.map(&.name)
      end
    end
  end
end
