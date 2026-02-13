require "http/web_socket"
require "json"
require "dns"
require "openssl/hmac"
require "openssl/cipher"
require "random/secure"

require "./homeconnect_local/types"
require "./homeconnect_local/entities"
require "./homeconnect_local/parser"
require "./homeconnect_local/discovery"
require "./homeconnect_local/tls_psk"
require "./homeconnect_local/runtime"
require "./homeconnect_local/runtime_builder"

# HomeConnect Local (minimal protocol client)
#
# Focus: AES mode first (ws://host:80/homeconnect) with custom AES+HMAC framing.
# TLS-PSK mode is supported via OpenSSL TLS 1.2 + PSK callback.
module HomeconnectLocal
  VERSION = "0.1.0"

  enum Action
    GET
    POST
    RESPONSE
    NOTIFY

    def to_s(io : IO)
      io << self.to_s
    end
  end

  # Message on the websocket (JSON).
  struct Message
    include JSON::Serializable

    @[JSON::Field(key: "sID", emit_null: false)]
    property sid : Int64? = nil
    @[JSON::Field(key: "msgID", emit_null: false)]
    property msg_id : Int64? = nil
    property resource : String
    @[JSON::Field(emit_null: false)]
    property version : Int32? = nil
    @[JSON::Field(ignore_serialize: true)]
    property action : Action = Action::GET
    @[JSON::Field(ignore_serialize: true)]
    property data : Array(JSON::Any) = [] of JSON::Any
    @[JSON::Field(emit_null: false)]
    property code : Int32? = nil

    def initialize(
      @resource : String,
      @action : Action = Action::GET,
      @data : Array(JSON::Any) = [] of JSON::Any,
      @sid : Int64? = nil,
      @msg_id : Int64? = nil,
      @version : Int32? = nil,
      @code : Int32? = nil,
    )
    end

    # Create a RESPONSE message matching this message.
    def respond(payload : Array(JSON::Any) = [] of JSON::Any) : Message
      Message.new(
        resource: resource,
        action: Action::RESPONSE,
        data: payload,
        sid: sid,
        msg_id: msg_id,
        version: version
      )
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "action", action.to_s.upcase
      unless data.empty?
        json.field "data", data
      end
    end

    # Parse appliance frames defensively. Some appliances occasionally send
    # boolean false for numeric envelope fields (for example code/version).
    def self.parse_loose(raw : String) : Message
      obj = JSON.parse(raw).as_h

      action = Action::GET
      if action_any = obj["action"]?
        if action_str = action_any.as_s?
          action = Action.parse?(action_str.upcase) || Action::GET
        end
      end

      data = [] of JSON::Any
      if data_any = obj["data"]?
        if arr = data_any.as_a?
          data = arr
        else
          data = [data_any]
        end
      end

      Message.new(
        resource: obj["resource"]?.try(&.as_s) || "/",
        action: action,
        data: data,
        sid: coerce_i64(obj["sID"]?),
        msg_id: coerce_i64(obj["msgID"]?),
        version: coerce_i32(obj["version"]?),
        code: coerce_i32(obj["code"]?)
      )
    end

    private def self.coerce_i64(any : JSON::Any?) : Int64?
      return nil unless any

      case raw = any.raw
      when Int64
        raw
      when Int32
        raw.to_i64
      when Float64
        raw.to_i64
      when String
        return nil if raw.empty? || raw == "false" || raw == "null"
        raw.to_i64?
      else
        nil
      end
    end

    private def self.coerce_i32(any : JSON::Any?) : Int32?
      v = coerce_i64(any)
      return nil unless v
      return nil if v < Int32::MIN || v > Int32::MAX
      v.to_i32
    end
  end

  class Error < Exception; end

  class NotConnected < Error; end

  class ProtocolError < Error; end

  class RemoteError < Error
    getter code : Int32
    getter resource : String

    def initialize(@code : Int32, @resource : String)
      super("Remote error code=#{code} resource=#{resource}")
    end
  end

  # AES transport with rolling HMAC chain, modelled after `homeconnect-websocket`.
  class AesFraming
    ENCRYPT_DIRECTION = 0x45_u8 # 'E'
    DECRYPT_DIRECTION = 0x43_u8 # 'C'

    @iv : Bytes
    @enckey : Bytes
    @mackey : Bytes
    @last_rx_hmac : Bytes
    @last_tx_hmac : Bytes

    def initialize(psk64 : String, iv64 : String)
      psk = HomeconnectLocal.decode_urlsafe_b64(psk64)
      @iv = HomeconnectLocal.decode_urlsafe_b64(iv64)
      @enckey = OpenSSL::HMAC.digest(:sha256, psk, "ENC")
      @mackey = OpenSSL::HMAC.digest(:sha256, psk, "MAC")
      @last_rx_hmac = Bytes.new(16, 0_u8)
      @last_tx_hmac = Bytes.new(16, 0_u8)
    end

    def encrypt(clear_text : String) : Bytes
      clear = clear_text.to_slice

      pad_len = 16 - (clear.size % 16)
      pad_len += 16 if pad_len == 1

      # clear + 0x00 + random(pad_len-2) + pad_len
      rnd = Random::Secure.random_bytes(pad_len - 2)
      padded = Bytes.new(clear.size + 1 + rnd.size + 1)
      clear.copy_to(padded[0, clear.size])
      padded[clear.size] = 0_u8
      rnd.copy_to(padded[clear.size + 1, rnd.size])
      padded[padded.size - 1] = pad_len.to_u8

      cipher = OpenSSL::Cipher.new("AES-256-CBC")
      cipher.encrypt
      cipher.key = @enckey
      cipher.iv = @iv
      cipher.padding = false

      enc = cipher.update(padded) + cipher.final

      hmac_input = Bytes.new(@iv.size + 1 + @last_tx_hmac.size + enc.size)
      idx = 0
      @iv.copy_to(hmac_input[idx, @iv.size]); idx += @iv.size
      hmac_input[idx] = ENCRYPT_DIRECTION; idx += 1
      @last_tx_hmac.copy_to(hmac_input[idx, @last_tx_hmac.size]); idx += @last_tx_hmac.size
      enc.copy_to(hmac_input[idx, enc.size])

      mac = OpenSSL::HMAC.digest(:sha256, @mackey, hmac_input)[0, 16]
      @last_tx_hmac = mac

      out = Bytes.new(enc.size + mac.size)
      out[0, enc.size].copy_from(enc)
      out[enc.size, mac.size].copy_from(mac)
      out
    end

    def decrypt(buf : Bytes) : String
      raise ProtocolError.new("Message too short") if buf.size < 32
      raise ProtocolError.new("Unaligned message") if (buf.size % 16) != 0

      enc = buf[0, buf.size - 16]
      recv_mac = buf[buf.size - 16, 16]

      hmac_input = Bytes.new(@iv.size + 1 + @last_rx_hmac.size + enc.size)
      idx = 0
      @iv.copy_to(hmac_input[idx, @iv.size]); idx += @iv.size
      hmac_input[idx] = DECRYPT_DIRECTION; idx += 1
      @last_rx_hmac.copy_to(hmac_input[idx, @last_rx_hmac.size]); idx += @last_rx_hmac.size
      enc.copy_to(hmac_input[idx, enc.size])

      calc = OpenSSL::HMAC.digest(:sha256, @mackey, hmac_input)[0, 16]
      unless HomeconnectLocal.secure_compare(recv_mac, calc)
        raise ProtocolError.new("HMAC failure")
      end
      @last_rx_hmac = recv_mac

      cipher = OpenSSL::Cipher.new("AES-256-CBC")
      cipher.decrypt
      cipher.key = @enckey
      cipher.iv = @iv
      cipher.padding = false

      msg = cipher.update(enc) + cipher.final
      pad_len = msg[msg.size - 1]
      raise ProtocolError.new("Padding error") if msg.size < pad_len

      clear = msg[0, msg.size - pad_len]
      String.new(clear)
    end
  end

  enum TransportMode
    AES
    TLS_PSK
  end

  # Minimal client:
  # - connect ws://host:80/homeconnect (AES framing) OR wss://host:443/homeconnect (TLS-PSK)
  # - perform handshake sequence
  # - provide send_sync waiting for responses
  class Client
    include Transport

    getter host : String
    getter? connected : Bool
    getter mode : TransportMode
    property? keepalive_enabled : Bool
    property keepalive_idle_timeout : Time::Span
    property keepalive_probe_interval : Time::Span
    property keepalive_status_uid : Int32?

    @ws : HTTP::WebSocket?
    @framing : AesFraming?
    @tls : OpenSSL::SSL::Context::Client?

    @sid : Int64?
    @next_msg_id : Int64 = 1
    @service_versions = {} of String => Int32
    @handshake_started : Bool = false
    @handshake_error : Exception? = nil
    @closed : Bool = false
    @last_rx_at : Time = Time.utc
    @last_keepalive_at : Time = Time.utc
    @keepalive_loop_generation : Int64 = 0
    @keepalive_fallback_uid : Int32?

    # msg_id -> channel
    @pending = {} of Int64 => Channel(Message)

    # callback for push notifications
    property on_notify : Proc(Message, Nil)?
    property? debug_frames : Bool = false

    def initialize(
      @host : String,
      psk64 : String,
      iv64 : String? = nil,
      @mode : TransportMode = TransportMode::AES,
      @psk_identity : String = "homeconnect",
      @tls_cipher : String = "PSK",
      @app_name : String = "Crystal",
      @app_id : String = Random::Secure.hex(4),
      keepalive_enabled : Bool = true,
      keepalive_idle_timeout : Time::Span = 60.seconds,
      keepalive_probe_interval : Time::Span = 10.seconds,
      keepalive_status_uid : Int32? = nil,
    )
      @keepalive_enabled = keepalive_enabled
      @keepalive_idle_timeout = keepalive_idle_timeout
      @keepalive_probe_interval = keepalive_probe_interval
      @keepalive_status_uid = keepalive_status_uid
      @keepalive_fallback_uid = keepalive_status_uid

      case @mode
      when TransportMode::AES
        raise ArgumentError.new("iv64 is required for AES mode") unless iv64
        @framing = AesFraming.new(psk64, iv64)
        @tls = nil
      when TransportMode::TLS_PSK
        @framing = nil
        @tls = TLS12PSK.build_client_context(psk64, identity: @psk_identity, cipher: @tls_cipher)
      end
      @connected = false
    end

    def connect(timeout : Time::Span = 60.seconds)
      @handshake_error = nil
      @handshake_started = false
      @closed = false
      @last_rx_at = Time.utc
      @last_keepalive_at = Time.utc
      @keepalive_loop_generation += 1
      case @mode
      when TransportMode::AES
        url = "ws://#{host}:80/homeconnect"
        @ws = HTTP::WebSocket.new(URI.parse(url))
      when TransportMode::TLS_PSK
        # Use host/port/path constructor so we can supply TLS context.
        tls = @tls || raise NotConnected.new("Missing TLS context")
        @ws = HTTP::WebSocket.new(host, "/homeconnect", 443, tls: tls)
      end

      ws = @ws || raise NotConnected.new("WebSocket initialization failed")

      ws.on_binary do |bytes|
        mark_rx_activity
        if @mode == TransportMode::AES
          json = ""
          begin
            debug_log("RX binary len=#{bytes.size}")
            framing = @framing || raise ProtocolError.new("Missing AES framing")
            json = framing.decrypt(bytes)
            debug_log("RX #{json}")
            msg = Message.parse_loose(json)
            handle_message(msg)
          rescue ex
            STDERR.puts "[homeconnect] decode error: #{format_exception(ex)}"
            if json.empty?
              STDERR.puts "[homeconnect] decode payload (binary hex): #{bytes.hexstring}"
            else
              STDERR.puts "[homeconnect] decode payload (json): #{json}"
            end
          end
        else
          STDERR.puts "[homeconnect] unexpected binary frame (TLS) len=#{bytes.size}"
        end
      end

      ws.on_message do |text|
        mark_rx_activity
        if @mode == TransportMode::TLS_PSK
          begin
            debug_log("RX #{text}")
            msg = Message.parse_loose(text)
            handle_message(msg)
          rescue ex
            STDERR.puts "[homeconnect] json decode error: #{format_exception(ex)}"
            STDERR.puts "[homeconnect] decode payload (json): #{text}"
          end
        else
          # AES mode should be binary; log text if happens
          STDERR.puts "[homeconnect] text frame: #{text}"
        end
      end

      ws.on_close do |code, reason|
        @closed = true
        @connected = false
        @keepalive_loop_generation += 1
        STDERR.puts "[homeconnect] closed #{code} #{reason}"
        @handshake_error ||= NotConnected.new("WebSocket closed #{code} #{reason}")
      end

      # Run socket in a fiber
      spawn do
        begin
          ws.run
        rescue ex
          @handshake_error ||= ex
          STDERR.puts "[homeconnect] websocket error: #{format_exception(ex)}"
        end
      end

      start_keepalive_loop

      # Wait until handshake completes
      deadline = Time.instant + timeout
      until @connected
        if ex = @handshake_error
          raise NotConnected.new("Handshake failed: #{format_exception(ex)}")
        end
        raise NotConnected.new("Handshake timeout") if Time.instant > deadline
        sleep 50.milliseconds
      end
      if ex = @handshake_error
        raise NotConnected.new("Handshake failed: #{format_exception(ex)}")
      end
    end

    def close
      @closed = true
      @keepalive_loop_generation += 1
      @ws.try &.close
      @connected = false
    end

    # Use the first settings entry from parsed XML for idle keepalive probes.
    # Falls back to status entries if settings are unavailable.
    def keepalive_status_from_description=(description : DeviceDescription)
      if setting = description.setting.first?
        @keepalive_status_uid = setting.uid
        @keepalive_fallback_uid = setting.uid
        return
      end

      chosen = description.status.find do |status|
        readable_access?(status.access) && (status.available != false)
      end
      uid = chosen.try(&.uid) || description.status.first?.try(&.uid)
      @keepalive_status_uid = uid
      @keepalive_fallback_uid = uid
    end

    # Send request and wait for matching RESPONSE.
    def send_sync(msg : Message, timeout : Time::Span = 15.seconds) : Message
      raise NotConnected.new unless @ws && (@connected || @handshake_started)

      prepared = prepare_message(msg)
      msg_id = prepared.msg_id || raise ProtocolError.new("Message ID missing after prepare")
      ch = Channel(Message).new(1)
      @pending[msg_id] = ch
      send_prepared(prepared)

      begin
        rsp = select
        when v = ch.receive
          v
        when timeout(timeout)
          raise NotConnected.new("Timeout waiting for response")
        end

        if code = rsp.code
          raise RemoteError.new(code, rsp.resource)
        end
        rsp
      ensure
        @pending.delete(msg_id)
      end
    end

    def send(msg : Message)
      prepared = prepare_message(msg)
      send_prepared(prepared)
    end

    private def send_prepared(msg : Message)
      ws = @ws || raise NotConnected.new
      payload = msg.to_json
      debug_log("TX #{payload}")
      case @mode
      when TransportMode::AES
        framing = @framing || raise ProtocolError.new("Missing AES framing")
        bytes = framing.encrypt(payload)
        debug_log("TX binary len=#{bytes.size}")
        ws.send(bytes)
      when TransportMode::TLS_PSK
        ws.send(payload)
      end
    end

    # --- handshake (minimal) ---

    private def handle_message(msg : Message)
      if msg.resource == "/ei/initialValues"
        return if @connected || @handshake_started
        @handshake_started = true
        spawn do
          begin
            perform_handshake(msg)
          rescue ex
            @handshake_error = ex
            STDERR.puts "[homeconnect] handshake error: #{format_exception(ex)}"
          ensure
            @handshake_started = false
          end
        end
        return
      end

      if msg.action == Action::RESPONSE
        if id = msg.msg_id
          if ch = @pending[id]?
            ch.send(msg)
          end
        end
      elsif msg.action == Action::NOTIFY
        on_notify.try &.call(msg)
      end
    end

    private def perform_handshake(msg : Message)
      @sid = msg.sid
      # edMsgID is inside data[0]["edMsgID"]
      begin
        data = msg.data
        if data.size > 0
          first = data[0].as_h
          @next_msg_id = first["edMsgID"].as_i64
        end
      rescue
        # ignore
      end

      # respond to initial values
      payload = JSON.parse([{
        "deviceType" => "Application",
        "deviceName" => @app_name,
        "deviceID"   => @app_id,
      }].to_json).as_a
      send(msg.respond(payload))

      # request services
      services = Message.new(resource: "/ci/services", action: Action::GET, version: 1)
      rsp = send_sync(services, 15.seconds)
      set_service_versions(rsp)

      # optional auth for older ci
      if @service_versions["ci"]? && @service_versions["ci"] < 3
        nonce = HomeconnectLocal.urlsafe_b64_no_pad(Random::Secure.random_bytes(32))
        auth = Message.new(resource: "/ci/authentication", action: Action::GET, data: JSON.parse([{"nonce" => nonce}].to_json).as_a)
        send_sync(auth, 15.seconds)
        # try ci/info
        begin
          info = Message.new(resource: "/ci/info", action: Action::GET)
          send_sync(info, 15.seconds)
        rescue
        end
      end

      # iz/info if present
      if @service_versions.has_key?("iz")
        begin
          send_sync(Message.new(resource: "/iz/info", action: Action::GET), 15.seconds)
        rescue
        end
      end

      # device ready if ei v2
      if @service_versions["ei"]? == 2
        send(Message.new(resource: "/ei/deviceReady", action: Action::NOTIFY))
      end

      # ni/info if present
      if @service_versions.has_key?("ni")
        begin
          send_sync(Message.new(resource: "/ni/info", action: Action::GET), 15.seconds)
        rescue
        end
      end

      # sync descriptions & mandatory values
      begin
        send_sync(Message.new(resource: "/ro/allDescriptionChanges", action: Action::GET), 30.seconds)
        mandatory = send_sync(Message.new(resource: "/ro/allMandatoryValues", action: Action::GET), 30.seconds)
        learn_keepalive_uid_from_values(mandatory) unless @keepalive_status_uid
      rescue
      end

      return if @closed || @handshake_error
      @connected = true
    end

    private def set_service_versions(msg : Message)
      data = msg.data
      data.each do |e|
        h = e.as_h
        service = h["service"].as_s
        ver = h["version"].as_i.to_i32
        @service_versions[service] = ver
      end
    end

    private def prepare_message(msg : Message) : Message
      prepared = msg
      prepared.sid = @sid unless prepared.sid
      prepared.version ||= @service_versions[prepared.resource[1, 2]]? || 1
      if prepared.msg_id.nil?
        prepared.msg_id = @next_msg_id
        @next_msg_id += 1
      end
      prepared
    end

    private def format_exception(ex : Exception) : String
      msg = ex.message
      bt = ex.backtrace?
      first_bt = bt && bt.size > 0 ? bt[0] : nil
      out = String.build do |io|
        io << ex.class.name
        if msg && !msg.empty?
          io << ": " << msg
        end
        if first_bt
          io << " @ " << first_bt
        end
      end
      out
    end

    private def debug_log(message : String)
      return unless @debug_frames
      STDERR.puts "[homeconnect][frame] #{message}"
    end

    private def mark_rx_activity
      @last_rx_at = Time.utc
    end

    private def start_keepalive_loop
      generation = @keepalive_loop_generation
      spawn do
        loop do
          sleep @keepalive_probe_interval
          break if generation != @keepalive_loop_generation
          break if @closed
          next unless @connected
          next unless keepalive_enabled?
          uid = @keepalive_status_uid
          next unless uid

          now = Time.utc
          idle = now - @last_rx_at
          since_last_probe = now - @last_keepalive_at
          next unless idle >= @keepalive_idle_timeout
          next if since_last_probe < @keepalive_idle_timeout

          begin
            debug_log("idle keepalive probe uid=#{uid} idle=#{idle.total_seconds}s")
            payload = JSON.parse([{"uid" => uid}].to_json).as_a
            keepalive = Message.new(resource: "/ro/values", action: Action::GET, data: payload)
            send_sync(keepalive, 15.seconds)
            @last_keepalive_at = Time.utc
          rescue ex : RemoteError
            if ex.code == 400
              STDERR.puts "[homeconnect] keepalive uid=#{uid} rejected (400), relearning uid"
              relearn_keepalive_uid
              @last_keepalive_at = Time.utc
            else
              STDERR.puts "[homeconnect] keepalive error: #{format_exception(ex)}"
            end
          rescue ex
            STDERR.puts "[homeconnect] keepalive error: #{format_exception(ex)}"
          end
        end
      end
    end

    private def learn_keepalive_uid_from_values(msg : Message)
      data = msg.data
      data.each do |entry_any|
        entry = entry_any.as_h?
        next unless entry
        uid_any = entry["uid"]?
        next unless uid_any
        uid = uid_any.as_i?.try(&.to_i32)
        next unless uid
        @keepalive_status_uid = uid
        return
      end
    end

    private def relearn_keepalive_uid
      if uid = @keepalive_fallback_uid
        @keepalive_status_uid = uid
        return
      end

      mandatory = send_sync(Message.new(resource: "/ro/allMandatoryValues", action: Action::GET), 15.seconds)
      learn_keepalive_uid_from_values(mandatory)
    rescue
      # If relearn fails, stop probing until caller configures a uid again.
      @keepalive_status_uid = nil
    end

    private def readable_access?(access : Access?) : Bool
      case access
      when Access::READ, Access::READ_WRITE, Access::READ_STATIC
        true
      else
        false
      end
    end
  end

  # --- helpers ---

  def self.decode_urlsafe_b64(s : String) : Bytes
    # add padding up to multiple of 4
    pad = (4 - (s.bytesize % 4)) % 4
    padded = s + ("=" * pad)
    Base64.urlsafe_decode(padded)
  end

  def self.urlsafe_b64_no_pad(bytes : Bytes) : String
    Base64.urlsafe_encode(bytes).gsub("=", "")
  end

  # constant-time compare
  def self.secure_compare(a : Bytes, b : Bytes) : Bool
    return false if a.size != b.size
    acc = 0
    a.size.times do |i|
      acc |= (a[i] ^ b[i]).to_i
    end
    acc == 0
  end
end
