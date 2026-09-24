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

```gleam
import gleam/int
import gleam/io
import puddle

pub fn main() {
  let assert Ok(manager) = puddle.start(4, fn() { Ok(int.random(8192)) }, 1000)

  let fun = fn(n) { n * 2 }

  // Use apply directly from the current process
  let result1 = {
    use r <- puddle.apply(manager, fun, 1000)
    r
  }
  io.debug(result1)

  let result2 = {
    use r <- puddle.apply(manager, fun, 1000)
    r
  }
  io.debug(result2)
}
```