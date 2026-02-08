require "openssl"
require "base64"

lib LibSSL
  alias PskClientCallback = (SSL, LibC::Char*, LibC::Char*, UInt32, UInt8*, UInt32 -> UInt32)
  fun SSL_CTX_set_psk_client_callback(ctx : SSLContext, cb : PskClientCallback) : Void
end

module HomeconnectLocal
  # TLS 1.2 + PSK support for Crystal/OpenSSL.
  #
  # Crystal's stdlib OpenSSL bindings don't expose PSK callbacks or min/max
  # protocol version setters, so we bridge to libssl directly.
  module TLS12PSK
    # OpenSSL TLS1_2_VERSION is 0x0303
    TLS1_2_VERSION = 0x0303

    # SSL_CTRL constants from openssl/ssl.h
    SSL_CTRL_SET_MIN_PROTO_VERSION = 123
    SSL_CTRL_SET_MAX_PROTO_VERSION = 124

    @@identity : String = "homeconnect"
    @@psk : Bytes = Bytes.empty

    # Keep callback alive (avoid GC)
    @@client_cb : ::LibSSL::PskClientCallback = ->(ssl : ::LibSSL::SSL, hint : LibC::Char*, identity_buf : LibC::Char*, max_identity_len : UInt32, psk_buf : UInt8*, max_psk_len : UInt32) : UInt32 {
      # ---- Identity (NUL-terminated) ----
      id = @@identity.to_slice
      return 0_u32 if id.size + 1 > max_identity_len
      id_out = Slice.new(identity_buf, id.size + 1)
      id.copy_to(id_out)
      id_out[id.size] = 0_u8

      # ---- PSK bytes ----
      return 0_u32 if @@psk.size > max_psk_len
      psk_out = Slice.new(psk_buf, @@psk.size)
      @@psk.copy_to(psk_out)
      @@psk.size.to_u32
    }

    def self.decode_psk64(psk64 : String) : Bytes
      # urlsafe base64 with optional missing padding
      pad = (4 - (psk64.bytesize % 4)) % 4
      padded = pad == 0 ? psk64 : (psk64 + ("=" * pad))
      Base64.decode(padded)
    end

    private def self.set_tls12_only!(raw : ::LibSSL::SSLContext)
      if ::LibSSL.ssl_ctx_ctrl(raw, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION.to_u64, Pointer(Void).null) <= 0
        raise "SSL_CTRL_SET_MIN_PROTO_VERSION failed"
      end
      if ::LibSSL.ssl_ctx_ctrl(raw, SSL_CTRL_SET_MAX_PROTO_VERSION, TLS1_2_VERSION.to_u64, Pointer(Void).null) <= 0
        raise "SSL_CTRL_SET_MAX_PROTO_VERSION failed"
      end
    end

    # Build a client context that negotiates PSK over TLS 1.2.
    #
    # cipher defaults to "PSK" (lets OpenSSL negotiate any PSK cipher suite supported
    # by both peers). You may pass a narrower cipher string if you need.
    def self.build_client_context(psk64 : String, identity : String = "homeconnect", cipher : String = "PSK") : OpenSSL::SSL::Context::Client
      @@psk = decode_psk64(psk64)
      @@identity = identity

      ctx = OpenSSL::SSL::Context::Client.new
      ctx.ciphers = cipher
      ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE

      raw = ctx.to_unsafe
      set_tls12_only!(raw)
      ::LibSSL.SSL_CTX_set_psk_client_callback(raw, @@client_cb)

      ctx
    end
  end
end
