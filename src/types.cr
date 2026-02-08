require "json"

module HomeconnectLocal
  # Mirrors python Access enum values.
  enum Access
    NONE
    READ
    READ_WRITE
    WRITE_ONLY
    READ_STATIC

    def self.parse_loose(s : String) : Access
      case s.downcase
      when "none"       then NONE
      when "read"       then READ
      when "readwrite"  then READ_WRITE
      when "writeonly"  then WRITE_ONLY
      when "readstatic" then READ_STATIC
      else
        NONE
      end
    end
  end

  enum Execution
    NONE
    SELECT_ONLY
    START_ONLY
    SELECT_AND_START

    def self.parse_loose(s : String) : Execution
      case s.downcase
      when "none"            then NONE
      when "selectonly"      then SELECT_ONLY
      when "startonly"       then START_ONLY
      when "selectandstart"  then SELECT_AND_START
      else
        SELECT_AND_START
      end
    end
  end

  # A lightweight entity description used by the XML parser.
  struct EntityDesc
    getter uid : Int32
    getter name : String
    getter protocol_type : String?
    getter content_type : String?
    getter access : Access?
    getter available : Bool?
    getter min : Float64?
    getter max : Float64?
    getter step : Float64?
    getter enum_map : Hash(Int32, String)?
    getter options : Array(Int32) # option refUIDs for Programs
    getter execution : Execution?

    def initialize(
      @uid : Int32,
      @name : String,
      @protocol_type : String? = nil,
      @content_type : String? = nil,
      @access : Access? = nil,
      @available : Bool? = nil,
      @min : Float64? = nil,
      @max : Float64? = nil,
      @step : Float64? = nil,
      @enum_map : Hash(Int32, String)? = nil,
      @options : Array(Int32) = [] of Int32,
      @execution : Execution? = nil
    )
    end
  end

  struct DeviceDescription
    getter info : Hash(String, JSON::Any)
    getter status : Array(EntityDesc)
    getter setting : Array(EntityDesc)
    getter event : Array(EntityDesc)
    getter command : Array(EntityDesc)
    getter option : Array(EntityDesc)
    getter program : Array(EntityDesc)
    getter active_program : EntityDesc?
    getter selected_program : EntityDesc?

    def initialize(
      @info : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @status : Array(EntityDesc) = [] of EntityDesc,
      @setting : Array(EntityDesc) = [] of EntityDesc,
      @event : Array(EntityDesc) = [] of EntityDesc,
      @command : Array(EntityDesc) = [] of EntityDesc,
      @option : Array(EntityDesc) = [] of EntityDesc,
      @program : Array(EntityDesc) = [] of EntityDesc,
      @active_program : EntityDesc? = nil,
      @selected_program : EntityDesc? = nil
    )
    end
  end
end
