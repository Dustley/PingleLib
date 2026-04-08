![Logo](PingleLogo.png)
# Pingle
`Pingle` is a networking library for Figura.

It acts as a wraper for pings and handles the annoying parts for you! key features include:  

- Automatically Synced values  
- Ping (size/count) limits  
- Ping Compression  
- Buffered Pings  
- Network events

---

## Important Info:

Host-only send APIs will error on clients, these include: 

- `Pingle.synced.set(...)`
- `Pingle.event.emit(...)`
- `Pingle.immediate.send(...)`

---

## Setup

Its as simple as require-ing the script:

```lua
local Pingle =  require "src.library.pingle-lib.pingle"
```

(Optional) feel free to set debug output to show some useful info:

```lua
Pingle.debug = true
```

And thats it, your all set up!

---

## Quick Start

```lua
local Pingle =  require "src.library.pingle-lib.pingle"

-- Optional debug output
Pingle.debug = true

-- Synced value with receive callback
Pingle.synced.define("demo.counter", 0, function(value, key)
  print("[demo] synced update", key, value)
end)

-- Event handler/listener
Pingle.event.register("demo.announce", function(data)
  print("[demo] handler:", data.message)
end)

Pingle.event.listen("demo.announce", function(data)
  print("[demo] listener:", data.message)
end)

events.INIT:register(function() 
  -- Host sends
  if Pingle.isHost() then
    Pingle.synced.set("demo.counter", 1)
    Pingle.event.emit("demo.announce", { message = "Hello from host!" })
    Pingle.immediate.send("demo.announce", { message = "Immediate ping path" })
  end
end)
```

---

## API Reference

## `Pingle.synced`

### `Pingle.synced.define(key, initialValue, onReceive?)`

Registers a synced key.

- `key` (`string`) unique key name.
- `initialValue` (`any pingable`) local initial value.
- `onReceive` (`function(value, key)`_optional):
  - **Non-Host**: runs when an incoming packet **changes** the stored value (`old ~= new`).
  - **Host**: after you call `synced.set`, the value is updated **before** the ping echo; the echo often reapplies the **same** value, so the receive path skips `onReceive` to avoid doubles. By default the host also runs `onReceive` **from `synced.set`** right after queueing (see `Pingle.syncedFireOnHostSet`).

### `Pingle.synced.get(key)`

Returns latest local value for a synced key, or `nil`.

### `Pingle.synced.set(key, value)` (host-only)

Sets local value and queues it for non hosts to grab.

Notes:

- Only the latest value is sent. (if setting in rapid sucession)
- If unchanged (`==`), the value is not re-queued.
- If `Pingle.syncedFireOnHostSet` is `true` (default), the `onReceive` callback runs once after a successful host `set`.

### `Pingle.syncedFireOnHostSet`

- Default `true`. Set to `false` if you only want `onReceive` on **network apply** (you will usually not see it on the host for your own `set` when the echoed value matches).

---

## `Pingle.event`

### `Pingle.event.register(name, handler)`

Registers the primary handler for event name.

- `name` (`string`) event id.
- `handler` (`function(dataTable)`).

### `Pingle.event.listen(name, listener)`

Adds an extra listener for that event name.

- `listener` (`function(dataTable)`).

### `Pingle.event.emit(name, dataTable?)` (host-only)

Queues buffered event packet.

- `dataTable` should be a small table (tables cost more bytes).

---

## `Pingle.immediate`

### `Pingle.immediate.send(name, dataTable?)` (host-only)

Queues an immediate-rate-limited send.

Use for urgent/lightweight messages that should not wait for buffered coalescing.

---

## Other Public Members

### `Pingle.isHost()`

Returns whether this script instance is host. (is literally just host.isHost())

### `Pingle._tick(dt)`

Internal tick/update function called from `events.TICK`.  
You normally do not call this yourself.

---

## Performance + Limits

Pingle is set just under Figura backend constraints:

- max backend limits are roughly `1024 bytes/sec` and `32 pings/sec`,
- pingle defaults are conservative (`768 bytes/sec`, `28 pings/sec`),
- buffered channel flushes at `3` times per second,
- large payloads are chunked and reassembled.

Avoid sending huge tables frequently, instead send:

- numbers,
- booleans,
- short strings,
- segmented state updates,
- event payloads with only needed fields.

---

## Config Knobs

You can tweak these at runtime:

- `Pingle.bytesPerSecondBudget` (default = 768)
- `Pingle.pingsPerSecondBudget` (default = 28)
- `Pingle.bufferFlushPerSecond` (default = 3)
- `Pingle.maxChunkPayload` (default = 240)
- `Pingle.maxQueueRecords` (default = 256)
- `Pingle.maxTableDepth` (default = 32)
- `Pingle.maxTablePairs` (default = 48)
- `Pingle.maxStringLen` (default = 8000)
- `Pingle.syncedFireOnHostSet` — when `true` (default), `synced.set` on the host also calls `onReceive` after queueing so the host sees the same path as clients.
- `Pingle.debug`

Setting config example:

```lua
Pingle.bufferFlushPerSecond = 3
Pingle.bytesPerSecondBudget = 768
Pingle.debug = true
```

---

## Tips / Gotchas

- **Every viewer must run the same** `Pingle.synced.define` **/** `Pingle.event.register` **setup as the host does.** If a friend’s client never executed that init, `onReceive` does not exist there and causes problems. 
- Use `Pingle.debug` for decode/sync hints (must be enabled in the **receiver’s** Lua, not only the host).
- Keep event payload tables as small as possible to free up bandwith.
- If you need continuous state sync, use `synced` keys (they segment very well).
- Use `immediate` for short urgent messages, not bulk data. (this is effectively the same as a regular ping with safeguards)
- If sending raw byte arrays, pack to strings (ASCII bytes) before sending.

