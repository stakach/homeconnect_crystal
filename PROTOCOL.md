# Home Connect Local protocol (reverse-engineered from `homeconnect_local_hass`)

Source repos inspected:
- HA integration: https://github.com/chris-mc1/homeconnect_local_hass/
- Underlying protocol lib used by integration: `homeconnect-websocket==1.4.5`

This document captures what matters for implementing an adapter in another system.

---

## 1. Transport

Home Connect “local” uses **WebSocket** to the appliance:

- **Path:** `/homeconnect`
- **AES mode:** `ws://<host>:80/homeconnect`
- **TLS-PSK mode:** `wss://<host>:443/homeconnect`

No separate REST API is required by this implementation; commands/events are JSON messages over the websocket.

Discovery (optional): devices advertise `_homeconnect._tcp.local.` via Zeroconf (used by HA integration).

* sets host as either "{brand}-{type}-{haId}" (TLS mode) or just haId (AES mode)
* Path: /homeconnect
* Port 80: ws://{host}:80/homeconnect
* Port 443: wss://{host}:443/homeconnect

Use the [Home Connect Profile Downloader](https://github.com/bruestel/homeconnect-profile-downloader) to download your Appliance profiles, select "openHAB" as target. The downloaded ZIP-file contains each Appliance encryption Key and feature descriptions

---

## 2. Crypto / authentication

There is no username/password authentication to the appliance. Instead, you use per-appliance keys from a downloaded “profile” file:

- `psk64`: urlsafe base64 pre-shared key
- `iv64`: urlsafe base64 IV (AES mode only)
- connection type: `TLS` or `AES` (from profile)

### 2.1 TLS-PSK mode (wss)

The protocol library uses TLS 1.2 and a **PSK** cipher suite. Certificate verification is disabled.

> Crystal/OpenSSL PSK support may be limited. For now, this Crystal library skeleton focuses on AES mode first; TLS-PSK can be added later if the runtime supports PSK ciphers.

### 2.2 AES mode (ws + custom framing)

AES mode wraps websocket binary frames with:

- AES-CBC encryption using `enckey`
- HMAC-SHA256-based integrity using `mackey` with a rolling 16-byte MAC chain

Key derivation from PSK bytes:

- `enckey = HMAC_SHA256(psk, "ENC")`
- `mackey = HMAC_SHA256(psk, "MAC")`

Message send (cleartext -> ciphertext):

1) Convert cleartext JSON string to bytes.
2) Padding scheme:
   - pad_len = 16 - (len % 16)
   - if pad_len == 1, add 16 (so minimum pad is 17)
   - append: `0x00` + random bytes + final byte `pad_len`
3) Encrypt with AES-CBC using IV from profile (static IV).
4) Compute rolling MAC (truncate to 16 bytes):

```
last_tx_hmac = 16*0x00 initially
hmac_input = iv + 'E' + last_tx_hmac + ciphertext
last_tx_hmac = HMAC_SHA256(mackey, hmac_input)[0,16]
```

5) Send websocket binary payload: `ciphertext || last_tx_hmac`.

Message receive (ciphertext -> cleartext):

1) Validate total length >= 32 and divisible by 16.
2) Split: `ciphertext = buf[0..-17]`, `recv_hmac = buf[-16..]`.
3) Verify rolling MAC:

```
last_rx_hmac = 16*0x00 initially
hmac_input = iv + 'C' + last_rx_hmac + ciphertext
calc_hmac = HMAC_SHA256(mackey, hmac_input)[0,16]
assert recv_hmac == calc_hmac
last_rx_hmac = recv_hmac
```

4) AES-CBC decrypt ciphertext.
5) Read pad_len = last byte; strip pad_len bytes.
6) UTF-8 decode remaining bytes; that’s the JSON message.

---

## 3. Message format

Messages are JSON objects with these keys:

```json
{
  "sID": 123,
  "msgID": 456,
  "resource": "/ci/services",
  "version": 1,
  "action": "GET"|"POST"|"NOTIFY"|"RESPONSE",
  "data": [ ... ],
  "code": 1234
}
```

Notes:
- `data` is always a list/array. If a single object is provided, it is wrapped.
- Responses correlate by `msgID`.
- `code` is set on error responses.

---

## 4. Session & handshake (app-level)

On connect, the appliance sends:
- `resource == "/ei/initialValues"`

The client should:

1) Reply with `action=RESPONSE` to `/ei/initialValues`:
   - payload includes `deviceName`, `deviceID`, and a `deviceType` (varies by version)

2) GET `/ci/services` (v1): receive service versions.

3) If CI version < 3: authenticate nonce
   - GET `/ci/authentication` with data `{nonce: <random base64url string>}`
   - then GET `/ci/info`

4) If `iz` exists: GET `/iz/info`

5) If `ei` version == 2: NOTIFY `/ei/deviceReady`

6) If `ni` exists: GET `/ni/info`

7) Sync state:
   - GET `/ro/allDescriptionChanges`
   - GET `/ro/allMandatoryValues`

After handshake:
- server pushes NOTIFY messages for:
  - `/ro/values`
  - `/ro/descriptionChange`

---

## 5. Command structure (resources)

This protocol is **resource-oriented**:
- resources are paths like `/ci/...`, `/ro/...`, `/ei/...`
- you send GET/POST/NOTIFY and receive RESPONSE/NOTIFY

The specific commands/options/programs are discovered from the appliance “device description” (profile XML in the downloader).

---

## 6. Minimal implementation plan

For an adapter:
- implement WebSocket connect
- implement AES framing (encrypt/decrypt + rolling MAC)
- implement JSON message encode/decode
- implement handshake sequence
- maintain state cache from NOTIFY updates
- implement `send_sync` that waits for RESPONSE with matching msgID

TLS-PSK can be implemented later once PSK support is confirmed in Crystal/OpenSSL.
