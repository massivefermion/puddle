![puddle](https://raw.githubusercontent.com/massivefermion/puddle/main/banner.jpg)

[![Package Version](https://img.shields.io/hexpm/v/puddle)](https://hex.pm/packages/puddle)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/puddle/)

# puddle

A resource pool manager for gleam

## <img width=32 src="https://raw.githubusercontent.com/massivefermion/puddle/main/icon.png"> Quick start

```sh
gleam test  # Run the tests
gleam shell # Run an Erlang shell
```

## <img width=32 src="https://raw.githubusercontent.com/massivefermion/puddle/main/icon.png"> Installation

This package can be added to your Gleam project:

```sh
gleam add puddle
```

and its documentation can be found at <https://hexdocs.pm/puddle>.

## <img width=32 src="https://raw.githubusercontent.com/massivefermion/puddle/main/icon.png"> Usage

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

### Pool status

```gleam
let status = puddle.status(manager, 1000)
// status.state: Ready | Full | Overloaded
// status.size, status.available, status.busy, status.waiting
```

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
