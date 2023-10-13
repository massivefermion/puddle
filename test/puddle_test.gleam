import gleam/int
import gleam/list
import gleam/string
import puddle
import gleeunit
import gleeunit/should
import gleam/erlang/file
import gleam/erlang/process

pub fn main() {
  gleeunit.main()
}

pub const test_output = "test_output"

pub fn parallel_test() {
  let manager =
    puddle.start_manager(
      3,
      fn() {
        int.random(1024, 8192)
        |> Ok
      },
    )
    |> should.be_ok

  let fun = fn(n) {
    let n_str = int.to_string(n)
    let _ = file.append(n_str <> " ", test_output)
    let _ = file.append(n_str <> " ", test_output)
    let _ = file.append(n_str <> " ", test_output)
    n_str
  }

  let sub1 =
    process.call(manager, puddle.Checkout, 32)
    |> should.be_ok

  let sub2 =
    process.call(manager, puddle.Checkout, 32)
    |> should.be_ok

  let sub3 =
    process.call(manager, puddle.Checkout, 32)
    |> should.be_ok

  let mine = process.new_subject()

  sub1
  |> process.send(puddle.UsageMessage(fun, mine))

  sub2
  |> process.send(puddle.UsageMessage(fun, mine))

  sub3
  |> process.send(puddle.UsageMessage(fun, mine))

  let selector =
    process.new_selector()
    |> process.selecting(mine, fn(r) { r })

  process.select(selector, 32)
  |> should.be_ok

  process.select(selector, 32)
  |> should.be_ok

  process.select(selector, 32)
  |> should.be_ok

  let _ =
    process.call(manager, puddle.Checkout, 32)
    |> should.be_error

  process.send(manager, puddle.PutBack(sub1))

  let _ =
    process.call(manager, puddle.Checkout, 32)
    |> should.be_ok

  let content =
    file.read(test_output)
    |> should.be_ok

  file.delete(test_output)
  |> should.be_ok

  let split_string = string.split(content, " ")
  let first =
    list.at(split_string, 0)
    |> should.be_ok

  let #(chains, _, _) =
    split_string
    |> list.fold(
      #([], [], first),
      fn(acc, n_str) {
        case n_str == acc.2 {
          True -> #(acc.0, list.prepend(acc.1, n_str), n_str)
          False ->
            case acc.1 {
              [] -> #(acc.0, [n_str], n_str)
              _ -> #(list.prepend(acc.0, acc.1), [n_str], n_str)
            }
        }
      },
    )

  // we could use `list.all`, which is stronger, but then the test would only almost always succeed!
  // but this is already enough to establish that `puddle` is able to run tasks in parallel
  chains
  |> list.any(fn(chain) { list.length(chain) < 3 })
  |> should.be_true
}
