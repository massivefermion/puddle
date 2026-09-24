import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import puddle
import simplifile

pub fn main() {
  gleeunit.main()
}

pub const test_output = "test_output"

fn task_async(fun: fn() -> a) -> #(process.Pid, process.Subject(a)) {
  let subject = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let result = fun()
      process.send(subject, result)
    })
  #(pid, subject)
}

fn task_await(
  task: #(process.Pid, process.Subject(a)),
  timeout: Int,
) -> Result(a, Nil) {
  let monitor = process.monitor(task.0)
  let selector =
    process.new_selector()
    |> process.select_map(task.1, fn(value) { Ok(value) })
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })

  case process.selector_receive(selector, timeout) {
    Ok(result) -> {
      process.demonitor_process(monitor)
      result
    }
    Error(Nil) -> {
      process.demonitor_process(monitor)
      Error(Nil)
    }
  }
}

fn crash_worker_and_wait(manager, sleep_ms) {
  let crash_task =
    task_async(fn() {
      use r <- puddle.apply(
        manager,
        fn(_) { panic as "intentional worker crash" },
        200,
      )
      r
    })

  task_await(crash_task, 1000)
  |> should.be_ok
  |> should.be_error

  process.sleep(sleep_ms)
}

pub fn parallel_test() {
  let manager =
    puddle.new(fn() {
      int.random(8192)
      |> Ok
    })
    |> puddle.size(3)
    |> puddle.start(32)
    |> should.be_ok

  let fun = fn(n) {
    let n_str = int.to_string(n)
    let _ = simplifile.append(to: test_output, contents: n_str <> " ")
    let _ = simplifile.append(to: test_output, contents: n_str <> " ")
    let _ = simplifile.append(to: test_output, contents: n_str <> " ")
    puddle.keep(n_str)
  }

  let t1 =
    task_async(fn() {
      use r <- puddle.apply(manager, fun, 32)
      r
    })

  let t2 =
    task_async(fn() {
      use r <- puddle.apply(manager, fun, 32)
      r
    })

  let t3 =
    task_async(fn() {
      use r <- puddle.apply(manager, fun, 32)
      r
    })

  let t4 =
    task_async(fn() {
      use r <- puddle.apply(manager, fun, 32)
      r
    })

  task_await(t1, 32)
  |> should.be_ok
  |> should.be_ok

  task_await(t2, 32)
  |> should.be_ok
  |> should.be_ok

  task_await(t3, 32)
  |> should.be_ok
  |> should.be_ok

  task_await(t4, 32)
  |> should.be_ok
  |> should.be_error

  let t =
    task_async(fn() {
      use r <- puddle.apply(manager, fun, 32)
      r
    })

  task_await(t, 32)
  |> should.be_ok
  |> should.be_ok

  let content =
    simplifile.read(from: test_output)
    |> should.be_ok

  simplifile.delete(file_or_dir_at: test_output)
  |> should.be_ok

  let split_string = string.split(content, " ")
  let first =
    list.first(split_string)
    |> should.be_ok

  let #(chains, _, _) =
    split_string
    |> list.fold(#([], [], first), fn(acc, n_str) {
      case n_str == acc.2 {
        True -> #(acc.0, list.prepend(acc.1, n_str), n_str)
        False ->
          case acc.1 {
            [] -> #(acc.0, [n_str], n_str)
            _ -> #(list.prepend(acc.0, acc.1), [n_str], n_str)
          }
      }
    })

  chains
  |> list.any(fn(chain) { list.length(chain) < 3 })
  |> should.be_true

  Ok(Nil)
}

pub fn worker_crash_test() {
  let manager =
    puddle.new(fn() { Ok(8) })
    |> puddle.size(1)
    |> puddle.start(1000)
    |> should.be_ok

  crash_worker_and_wait(manager, 100)

  let t =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
      r
    })

  task_await(t, 2000)
  |> should.be_ok
  |> should.be_ok
  |> should.equal(8)
}

pub fn user_crash_test() {
  let manager =
    puddle.new(fn() { Ok(8) })
    |> puddle.size(1)
    |> puddle.start(1000)
    |> should.be_ok

  let crash_task =
    task_async(fn() {
      use _r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
      panic
    })

  task_await(crash_task, 1000)
  |> should.be_error

  process.sleep(100)

  let t =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
      r
    })

  task_await(t, 2000)
  |> should.be_ok
  |> should.be_ok
  |> should.equal(8)
}

pub fn explicit_checkin_test() {
  let manager =
    puddle.new(fn() { Ok(42) })
    |> puddle.size(1)
    |> puddle.start(1000)
    |> should.be_ok

  let r1 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n * 2) }, 1000)
    r
  }
  r1
  |> should.be_ok
  |> should.equal(84)

  let r2 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n + 1) }, 1000)
    r
  }
  r2
  |> should.be_ok
  |> should.equal(43)

  let r3 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  r3
  |> should.be_ok
  |> should.equal(42)
}

pub fn worker_crash_while_busy_test() {
  let manager =
    puddle.new(fn() { Ok(7) })
    |> puddle.size(2)
    |> puddle.start(1000)
    |> should.be_ok

  crash_worker_and_wait(manager, 200)

  let t1 =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
      r
    })
  let t2 =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
      r
    })

  task_await(t1, 2000)
  |> should.be_ok
  |> should.be_ok
  |> should.equal(7)

  task_await(t2, 2000)
  |> should.be_ok
  |> should.be_ok
  |> should.equal(7)
}

pub fn pool_exhaustion_and_recovery_test() {
  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(2)
    |> puddle.start(2000)
    |> should.be_ok

  let t1 =
    task_async(fn() {
      use r <- puddle.apply(
        manager,
        fn(n) {
          process.sleep(500)
          puddle.keep(n)
        },
        2000,
      )
      r
    })
  let t2 =
    task_async(fn() {
      use r <- puddle.apply(
        manager,
        fn(n) {
          process.sleep(500)
          puddle.keep(n)
        },
        2000,
      )
      r
    })

  process.sleep(50)

  let t3 =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 100)
      r
    })

  task_await(t3, 500)
  |> should.be_ok
  |> should.be_error

  task_await(t1, 2000)
  |> should.be_ok
  |> should.be_ok

  task_await(t2, 2000)
  |> should.be_ok
  |> should.be_ok

  let t4 =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
      r
    })

  task_await(t4, 2000)
  |> should.be_ok
  |> should.be_ok
  |> should.equal(1)
}

pub fn sequential_reuse_test() {
  let manager =
    puddle.new(fn() { Ok(99) })
    |> puddle.size(1)
    |> puddle.start(1000)
    |> should.be_ok

  let r1 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  r1
  |> should.be_ok
  |> should.equal(99)

  let r2 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n + 1) }, 1000)
    r
  }
  r2
  |> should.be_ok
  |> should.equal(100)

  let r3 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n * 2) }, 1000)
    r
  }
  r3
  |> should.be_ok
  |> should.equal(198)

  let r4 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n - 10) }, 1000)
    r
  }
  r4
  |> should.be_ok
  |> should.equal(89)

  let r5 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n * n) }, 1000)
    r
  }
  r5
  |> should.be_ok
  |> should.equal(9801)
}

pub fn shutdown_test() {
  let shutdown_subject = process.new_subject()

  let manager =
    puddle.new(fn() { Ok(42) })
    |> puddle.size(2)
    |> puddle.on_shutdown(fn(_resource) {
      process.send(shutdown_subject, True)
    })
    |> puddle.start(5000)
    |> should.be_ok

  let _busy_task =
    task_async(fn() {
      use r <- puddle.apply(
        manager,
        fn(resource) {
          process.sleep(300)
          puddle.keep(resource)
        },
        5000,
      )
      r
    })

  process.sleep(50)

  puddle.shutdown(manager)

  let selector =
    process.new_selector()
    |> process.select_map(shutdown_subject, fn(value) { value })

  process.selector_receive(selector, 2000)
  |> should.be_ok
  |> should.equal(True)

  process.selector_receive(selector, 2000)
  |> should.be_ok
  |> should.equal(True)
}
