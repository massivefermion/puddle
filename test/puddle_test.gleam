import gleam/int
import gleam/list
import gleam/string
import puddle
import gleeunit
import gleeunit/should
import gleam/otp/task
import simplifile.{append, delete, read}

pub fn main() {
  gleeunit.main()
}

pub const test_output = "test_output"

pub fn parallel_test() {
  let manager =
    puddle.start(
      3,
      fn() {
        int.random(1024, 8192)
        |> Ok
      },
    )
    |> should.be_ok

  let fun = fn(n) {
    let n_str = int.to_string(n)
    let _ = append(test_output, n_str <> " ")
    let _ = append(test_output, n_str <> " ")
    let _ = append(test_output, n_str <> " ")
    n_str
  }

  let t1 =
    task.async(fn() {
      use r <- puddle.apply(manager, fun, 32)
      r
    })

  let t2 =
    task.async(fn() {
      use r <- puddle.apply(manager, fun, 32)
      r
    })

  let t3 =
    task.async(fn() {
      use r <- puddle.apply(manager, fun, 32)
      r
    })

  let t4 =
    task.async(fn() {
      use r <- puddle.apply(manager, fun, 32)
      r
    })

  task.await(t1, 32)
  |> should.be_ok

  task.await(t2, 32)
  |> should.be_ok

  task.await(t3, 32)
  |> should.be_ok

  task.await(t4, 32)
  |> should.be_error

  let t =
    task.async(fn() {
      use r <- puddle.apply(manager, fun, 32)
      r
    })

  task.await(t, 32)
  |> should.be_ok

  let content =
    read(test_output)
    |> should.be_ok

  delete(test_output)
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

  Ok(Nil)
}
