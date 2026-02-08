# homeconnect_local (Crystal)

Minimal Crystal library implementing the **Home Connect Local** websocket protocol (starting with AES mode).

- Protocol notes: [`PROTOCOL.md`](./PROTOCOL.md)

## Status

- AES mode: implemented (ws://host:80/homeconnect) with AES-CBC + rolling HMAC framing.
- TLS-PSK mode: implemented (wss://host:443/homeconnect) using OpenSSL TLS 1.2 + PSK callback.

## Usage (sketch)

### Example: interactive oven CLI (TLS-PSK)

See: `examples/oven_cli.cr`

```crystal
require "homeconnect_local"

client = HomeconnectLocal::Client.new(
  host: "192.168.1.50",
  psk64: "<urlsafe base64 psk from profile>",
  iv64: "<urlsafe base64 iv from profile>",
  app_name: "MyAdapter",
  app_id: "deadbeef"
)

client.on_notify = ->(msg : HomeconnectLocal::Message) {
  puts "NOTIFY #{msg.resource} #{msg.data}"
}

client.connect

rsp = client.send_sync(HomeconnectLocal::Message.new(resource: "/ci/info"))
puts rsp.data
```

## Development

```bash
crystal spec
```
