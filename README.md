# puddle

A resource pool manager for Gleam. Manages a fixed pool of reusable resources with automatic crash recovery and backpressure.

[![Package Version](https://img.shields.io/hexpm/v/puddle)](https://hex.pm/packages/puddle)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/puddle/)

## Installation

```sh
gleam add puddle
```

## Quick Start

### Basic usage

```gleam
import gleam/int
import gleam/io
import puddle

pub fn main() {
  let assert Ok(manager) =
    puddle.new(fn() { Ok(int.random(8192)) })
    |> puddle.size(4)
    |> puddle.start(1000)

  let result = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n * 2) }, 1000)
    r
  }
  io.debug(result)

  puddle.shutdown(manager)
}
```

### Resource discard

When a resource becomes invalid, signal the pool to destroy it and create a replacement:

```gleam
let result = {
  use r <- puddle.apply(manager, fn(conn) {
    case db.query(conn, "SELECT 1") {
      Ok(rows) -> puddle.keep(rows)
      Error(_) -> puddle.discard([])
    }
  }, 1000)
  r
}
```

### Blocking checkout

When all resources are busy, `apply_blocking` queues the request instead of returning an error:

```gleam
let result = {
  use r <- puddle.apply_blocking(manager, fn(n) { puddle.keep(n) }, 5000)
  r
}
```

### Named pools

Give a pool a name to access it globally without passing the manager reference:

```gleam
import gleam/erlang/process

let pool_name = process.new_name("my_db_pool")

let assert Ok(manager) =
  puddle.new(create_connection)
  |> puddle.size(10)
  |> puddle.name(pool_name)
  |> puddle.start(5000)

// Access from anywhere using the name
let named = process.named_subject(pool_name)
let result = {
  use r <- puddle.apply(named, fn(conn) { puddle.keep(conn) }, 1000)
  r
}
```

### Configuration options

```gleam
let assert Ok(manager) =
  puddle.new(create_connection)
  |> puddle.size(10)
  |> puddle.checkout_strategy(puddle.LIFO)
  |> puddle.creation_strategy(puddle.Lazy)
  |> puddle.on_shutdown(fn(conn) { db.close(conn) })
  |> puddle.start(5000)
```

#### Pool size

`puddle.size(n)` — maximum number of resources in the pool (default: 10).

#### Checkout strategy

`puddle.checkout_strategy(strategy)` — how idle resources are selected:
- `puddle.FIFO` (default) — oldest idle resource first, fair ordering
- `puddle.LIFO` — most recently returned resource first, better cache locality

#### Creation strategy

`puddle.creation_strategy(strategy)` — when resources are created:
- `puddle.Eager` (default) — create all resources at startup
- `puddle.Lazy` — create resources on first demand, up to `size`

#### Shutdown callback

`puddle.on_shutdown(fn(resource) { ... })` — called for each resource when the pool shuts down.

#### Pool name

`puddle.name(process.new_name("my_pool"))` — register the pool under a globally accessible name.

### Pool status

```gleam
let status = puddle.status(manager, 1000)
// status.state: Ready | Full | Overloaded
// status.size, status.available, status.busy, status.waiting
```

Pool states:
- `Ready` — idle resources available
- `Full` — all resources busy, no waiters
- `Overloaded` — all resources busy, requests queued

### OTP supervision

```gleam
import gleam/otp/static_supervisor

let child_spec =
  puddle.new(create_resource)
  |> puddle.size(5)
  |> puddle.supervised(5000)

let assert Ok(_supervisor) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(child_spec)
  |> static_supervisor.start
```

#### Named supervised pools

Combine `name` with `supervised` for globally accessible supervised pools:

```gleam
let pool_name = process.new_name("my_pool")

let child_spec =
  puddle.new(create_resource)
  |> puddle.size(5)
  |> puddle.name(pool_name)
  |> puddle.supervised(5000)

// Start under supervisor, then access anywhere via:
let manager = process.named_subject(pool_name)
```
