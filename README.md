# puddle

A resource pool manager for Gleam. Manages a fixed pool of reusable resources with automatic crash recovery and backpressure.

[![Package Version](https://img.shields.io/hexpm/v/puddle)](https://hex.pm/packages/puddle)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/puddle/)

## Installation

```sh
gleam add puddle
```

## Quick Start

```gleam
import gleam/int
import gleam/io
import puddle

pub fn main() {
  let assert Ok(manager) = puddle.start(4, fn() { Ok(int.random(8192)) }, 1000)

  let result = {
    use r <- puddle.apply(manager, fn(n) { n * 2 }, 1000)
    r
  }
  io.debug(result) // Ok(16384)
}
```

## API

| Function | Description |
|----------|-------------|
| `start(size, create_resource, timeout)` | Creates and starts the pool |
| `apply(manager, fun, timeout)` | Checks out resource, runs `fun`, checks in |
| `shutdown(manager, shutdown_resource)` | Gracefully stops the pool |

## Features

- **Fixed-size pool** — predictable resource usage
- **Automatic crash recovery** — workers replaced on failure
- **Backpressure** — `apply` returns `Error(Nil)` immediately when exhausted
- **Graceful shutdown** — drains busy workers before stopping
- **Gleam `use` syntax** — automatic check-in via `use r <- puddle.apply(...)`

## Documentation

Full API documentation: <https://hexdocs.pm/puddle/>

## Testing

```sh
gleam test
```

## License

Apache-2.0