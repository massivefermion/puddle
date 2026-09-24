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
        fn(_) {
          let assert 2 = 4
        },
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
    puddle.start(
      3,
      fn() {
        int.random(8192)
        |> Ok
      },
      32,
    )
    |> should.be_ok

  let fun = fn(n) {
    let n_str = int.to_string(n)
    let _ = simplifile.append(to: test_output, contents: n_str <> " ")
    let _ = simplifile.append(to: test_output, contents: n_str <> " ")
    let _ = simplifile.append(to: test_output, contents: n_str <> " ")
    n_str
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

  // we could use `list.all`, which is stronger, but then the test would only almost always succeed!
  // but this is already enough to establish that `puddle` is able to run tasks in parallel
  chains
  |> list.any(fn(chain) { list.length(chain) < 3 })
  |> should.be_true

  Ok(Nil)
}

pub fn worker_crash_test() {
  let manager =
    puddle.start(1, fn() { Ok(8) }, 1000)
    |> should.be_ok

  crash_worker_and_wait(manager, 100)

  let t =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { n }, 1000)
      r
    })

  task_await(t, 2000)
  |> should.be_ok
  |> should.be_ok
  |> should.equal(8)
}

pub fn user_crash_test() {
  let manager =
    puddle.start(1, fn() { Ok(8) }, 1000)
    |> should.be_ok

  // Spawn task where the user function succeeds but the caller panics
  // after apply returns. The resource is checked back in before the panic.
  let crash_task =
    task_async(fn() {
      use _r <- puddle.apply(manager, fn(n) { n }, 1000)
      panic
    })

  // Wait for the crash task: the process panics so task_await detects it
  // via the monitor and returns Error
  task_await(crash_task, 1000)
  |> should.be_error

  // Give the pool time to process the user's ProcessDown
  process.sleep(100)

  let t =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { n }, 1000)
      r
    })

  task_await(t, 2000)
  |> should.be_ok
  |> should.be_ok
  |> should.equal(8)
}

pub fn explicit_checkin_test() {
  let manager =
    puddle.start(1, fn() { Ok(42) }, 1000)
    |> should.be_ok

  // Apply multiple times from the same process sequentially
  // Each call checks out and checks back in the resource via explicit check-in
  let r1 = {
    use r <- puddle.apply(manager, fn(n) { n * 2 }, 1000)
    r
  }
  r1
  |> should.be_ok
  |> should.equal(84)

  let r2 = {
    use r <- puddle.apply(manager, fn(n) { n + 1 }, 1000)
    r
  }
  r2
  |> should.be_ok
  |> should.equal(43)

  let r3 = {
    use r <- puddle.apply(manager, fn(n) { n }, 1000)
    r
  }
  r3
  |> should.be_ok
  |> should.equal(42)
}

pub fn worker_crash_while_busy_test() {
  let manager =
    puddle.start(2, fn() { Ok(7) }, 1000)
    |> should.be_ok

  crash_worker_and_wait(manager, 200)

  // Check out 2 resources to prove full pool capacity is maintained
  let t1 =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { n }, 1000)
      r
    })
  let t2 =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { n }, 1000)
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
    puddle.start(2, fn() { Ok(1) }, 2000)
    |> should.be_ok

  // Launch 2 tasks that hold resources for 500ms
  let t1 =
    task_async(fn() {
      use r <- puddle.apply(
        manager,
        fn(n) {
          process.sleep(500)
          n
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
          n
        },
        2000,
      )
      r
    })

  // Small delay to ensure t1 and t2 have checked out their resources
  process.sleep(50)

  // 3rd task should fail because the pool is exhausted (no idle workers)
  let t3 =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { n }, 100)
      r
    })

  // The pool immediately responds with Error when no workers are idle
  task_await(t3, 500)
  |> should.be_ok
  |> should.be_error

  // Wait for the first 2 tasks to complete and return their resources
  task_await(t1, 2000)
  |> should.be_ok
  |> should.be_ok

  task_await(t2, 2000)
  |> should.be_ok
  |> should.be_ok

  // Now a checkout should succeed since resources have been returned
  let t4 =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { n }, 1000)
      r
    })

  task_await(t4, 2000)
  |> should.be_ok
  |> should.be_ok
  |> should.equal(1)
}

pub fn sequential_reuse_test() {
  let manager =
    puddle.start(1, fn() { Ok(99) }, 1000)
    |> should.be_ok

  // Call apply 5 times sequentially from the same process
  // This proves check-in works correctly for the same process reusing the pool
  let r1 = {
    use r <- puddle.apply(manager, fn(n) { n }, 1000)
    r
  }
  r1
  |> should.be_ok
  |> should.equal(99)

  let r2 = {
    use r <- puddle.apply(manager, fn(n) { n + 1 }, 1000)
    r
  }
  r2
  |> should.be_ok
  |> should.equal(100)

  let r3 = {
    use r <- puddle.apply(manager, fn(n) { n * 2 }, 1000)
    r
  }
  r3
  |> should.be_ok
  |> should.equal(198)

  let r4 = {
    use r <- puddle.apply(manager, fn(n) { n - 10 }, 1000)
    r
  }
  r4
  |> should.be_ok
  |> should.equal(89)

  let r5 = {
    use r <- puddle.apply(manager, fn(n) { n * n }, 1000)
    r
  }
  r5
  |> should.be_ok
  |> should.equal(9801)
}

pub fn shutdown_test() {
  let shutdown_subject = process.new_subject()

  let manager =
    puddle.start(2, fn() { Ok(42) }, 5000)
    |> should.be_ok

  // Check out one resource and keep it busy with a sleep
  let _busy_task =
    task_async(fn() {
      use r <- puddle.apply(
        manager,
        fn(resource) {
          process.sleep(300)
          resource
        },
        5000,
      )
      r
    })

  // Allow the checkout to be processed
  process.sleep(50)

  // Shutdown while one resource is busy and one is idle
  puddle.shutdown(manager, fn(_resource) {
    process.send(shutdown_subject, True)
  })

  // Wait for all shutdown messages (busy worker finishes its callback first)
  let selector =
    process.new_selector()
    |> process.select_map(shutdown_subject, fn(value) { value })

  // Should receive 2 notifications: one for the idle resource, one for the busy
  process.selector_receive(selector, 2000)
  |> should.be_ok
  |> should.equal(True)

  process.selector_receive(selector, 2000)
  |> should.be_ok
  |> should.equal(True)
}
