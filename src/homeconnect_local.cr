require "http/web_socket"
require "json"
require "openssl/hmac"
require "openssl/cipher"
require "random/secure"

require "./types"
require "./entities"
require "./parser"
require "./tls_psk"

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
    property sid : Int64?
    property msg_id : Int64?
    property resource : String
    property version : Int32?
    property action : Action
    property data : JSON::Any?
    property code : Int32?

    def initialize(
      @resource : String,
      @action : Action = Action::GET,
      @data : JSON::Any? = nil,
      @sid : Int64? = nil,
      @msg_id : Int64? = nil,
      @version : Int32? = nil,
      @code : Int32? = nil
    )
    end

    def to_json_string : String
      h = {
        "sID"     => sid,
        "msgID"   => msg_id,
        "resource" => resource,
        "version" => version,
        "action"  => action.to_s,
      }

      # Build JSON manually to ensure `data` is always an array when present.
      JSON.build do |json|
        json.object do
          json.field "sID", sid.not_nil! if sid
          json.field "msgID", msg_id.not_nil! if msg_id
          json.field "resource", resource
          json.field "version", version.not_nil! if version
          json.field "action", action.to_s

          if data
            # If data is already an Array, keep it; otherwise wrap.
            d = data.not_nil!
            if d.raw.is_a?(Array)
              json.field "data" do
                d.to_json(json)
              end
            else
              json.field "data" do
                json.array do
                  d.to_json(json)
                end
              end
            end
          end

          json.field "code", code.not_nil! if code
        end
      end
    end

    def self.from_json_string(str : String) : Message
      obj = JSON.parse(str).as_h
      sid = obj["sID"].as_i64
      msg_id = obj["msgID"].as_i64
      resource = obj["resource"].as_s
      version = obj["version"].as_i
      action = Action.parse(obj["action"].as_s)
      data = obj["data"]?
      code = obj["code"]?
      Message.new(
        resource: resource,
        action: action,
        data: data,
        sid: sid,
        msg_id: msg_id,
        version: version.to_i32,
        code: code ? code.as_i.to_i32 : nil
      )
    end

    # Create a RESPONSE message matching this message.
    def respond(payload : JSON::Any? = nil) : Message
      Message.new(
        resource: resource,
        action: Action::RESPONSE,
        data: payload,
        sid: sid,
        msg_id: msg_id,
        version: version
      )
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
    getter host : String
    getter connected : Bool
    getter mode : TransportMode

    @ws : HTTP::WebSocket?
    @framing : AesFraming?
    @tls : OpenSSL::SSL::Context::Client?

    @sid : Int64?
    @next_msg_id : Int64 = 1
    @service_versions = {} of String => Int32

    # msg_id -> channel
    @pending = {} of Int64 => Channel(Message)

    # callback for push notifications
    property on_notify : Proc(Message, Nil)?

    def initialize(
      @host : String,
      psk64 : String,
      iv64 : String? = nil,
      @mode : TransportMode = TransportMode::AES,
      @psk_identity : String = "homeconnect",
      @tls_cipher : String = "PSK",
      @app_name : String = "Crystal",
      @app_id : String = Random::Secure.hex(4)
    )
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
      case @mode
      when TransportMode::AES
        url = "ws://#{host}:80/homeconnect"
        @ws = HTTP::WebSocket.new(URI.parse(url))
      when TransportMode::TLS_PSK
        # Use host/port/path constructor so we can supply TLS context.
        @ws = HTTP::WebSocket.new(host, "/homeconnect", 443, tls: @tls.not_nil!)
      end

      ws = @ws.not_nil!

      ws.on_binary do |bytes|
        if @mode == TransportMode::AES
          begin
            json = @framing.not_nil!.decrypt(bytes)
            msg = Message.from_json_string(json)
            handle_message(msg)
          rescue ex
            STDERR.puts "[homeconnect] decode error: #{ex.message}"
          end
        else
          STDERR.puts "[homeconnect] unexpected binary frame (TLS) len=#{bytes.size}"
        end
      end

      ws.on_message do |text|
        if @mode == TransportMode::TLS_PSK
          begin
            msg = Message.from_json_string(text)
            handle_message(msg)
          rescue ex
            STDERR.puts "[homeconnect] json decode error: #{ex.message}"
          end
        else
          # AES mode should be binary; log text if happens
          STDERR.puts "[homeconnect] text frame: #{text}"
        end
      end

      ws.on_close do |code, reason|
        @connected = false
        STDERR.puts "[homeconnect] closed #{code} #{reason}"
      end

      # Run socket in a fiber
      spawn do
        ws.run
      end

      # Wait until handshake completes
      deadline = Time.instant + timeout
      until @connected
        raise NotConnected.new("Handshake timeout") if Time.instant > deadline
        sleep 50.milliseconds
      end
    end

    def close
      @ws.try &.close
      @connected = false
    end

    # Send request and wait for matching RESPONSE.
    def send_sync(msg : Message, timeout : Time::Span = 15.seconds) : Message
      raise NotConnected.new unless @connected

      prepare_message(msg)
      ch = Channel(Message).new(1)
      @pending[msg.msg_id.not_nil!] = ch
      send(msg)

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
        @pending.delete(msg.msg_id.not_nil!)
      end
    end

    def send(msg : Message)
      raise NotConnected.new unless @ws
      payload = msg.to_json_string
      case @mode
      when TransportMode::AES
        bytes = @framing.not_nil!.encrypt(payload)
        @ws.not_nil!.send(bytes)
      when TransportMode::TLS_PSK
        @ws.not_nil!.send(payload)
      end
    end

    # --- handshake (minimal) ---

    private def handle_message(msg : Message)
      if msg.resource == "/ei/initialValues"
        @sid = msg.sid
        # edMsgID is inside data[0]["edMsgID"]
        begin
          data = msg.data
          if data && (arr = data.as_a?) && arr.size > 0
            first = arr[0].as_h
            @next_msg_id = first["edMsgID"].as_i64
          end
        rescue
          # ignore
        end

        # respond to initial values
        payload = JSON.parse({
          "deviceType" => "Application",
          "deviceName" => @app_name,
          "deviceID"   => @app_id,
        }.to_json)
        send(msg.respond(payload))

        # request services
        services = Message.new(resource: "/ci/services", action: Action::GET, version: 1)
        rsp = send_sync(services, 15.seconds)
        set_service_versions(rsp)

        # optional auth for older ci
        if @service_versions["ci"]? && @service_versions["ci"] < 3
          nonce = HomeconnectLocal.urlsafe_b64_no_pad(Random::Secure.random_bytes(32))
          auth = Message.new(resource: "/ci/authentication", action: Action::GET, data: JSON.parse({"nonce" => nonce}.to_json))
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
          send_sync(Message.new(resource: "/ro/allMandatoryValues", action: Action::GET), 30.seconds)
        rescue
        end

        @connected = true
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

    private def set_service_versions(msg : Message)
      data = msg.data
      return unless data
      arr = data.as_a
      arr.each do |e|
        h = e.as_h
        service = h["service"].as_s
        ver = h["version"].as_i.to_i32
        @service_versions[service] = ver
      end
    end

    private def prepare_message(msg : Message)
      msg.sid = @sid unless msg.sid
      msg.version ||= @service_versions[msg.resource[1, 2]]? || 1
      if msg.msg_id.nil?
        msg.msg_id = @next_msg_id
        @next_msg_id += 1
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
