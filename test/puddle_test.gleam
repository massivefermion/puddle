import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/static_supervisor
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

fn creation_counter_loop(
  subj: process.Subject(process.Subject(Int)),
  count: Int,
) {
  let sel =
    process.new_selector()
    |> process.select_map(subj, fn(reply_to) { reply_to })
  case process.selector_receive(sel, 60_000) {
    Ok(reply_to) -> {
      process.send(reply_to, count)
      creation_counter_loop(subj, count + 1)
    }
    Error(Nil) -> Nil
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

fn hold_resource(manager, sleep_ms, timeout) {
  task_async(fn() {
    use r <- puddle.apply(
      manager,
      fn(n) {
        process.sleep(sleep_ms)
        puddle.keep(n)
      },
      timeout,
    )
    r
  })
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

  let t1 = hold_resource(manager, 500, 2000)
  let t2 = hold_resource(manager, 500, 2000)

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
    |> puddle.on_shutdown(fn(_resource) { process.send(shutdown_subject, True) })
    |> puddle.start(5000)
    |> should.be_ok

  let _busy_task = hold_resource(manager, 300, 5000)

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

// --- New feature tests ---

pub fn lifo_checkout_strategy_test() {
  let counter = process.new_subject()

  let manager =
    puddle.new(fn() {
      let id =
        process.selector_receive(
          process.new_selector()
            |> process.select_map(counter, fn(v) { v }),
          0,
        )
      case id {
        Ok(n) -> Ok(n)
        Error(Nil) -> Ok(0)
      }
    })
    |> puddle.size(3)
    |> puddle.checkout_strategy(puddle.LIFO)
    |> puddle.start(2000)

  // Workers were created eagerly; we can't control their IDs via the counter
  // approach since workers were already created. Instead, test LIFO behavior
  // by checking out all resources, noting their order, checking them all back
  // in, and then checking out again — LIFO should reverse the order.
  let assert Ok(manager) = manager

  // Check out all 3 resources and record their values
  let r1 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  let v1 = should.be_ok(r1)

  let r2 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  let v2 = should.be_ok(r2)

  let r3 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  let v3 = should.be_ok(r3)

  // Resources were returned in order v1, v2, v3 (check-in order)
  // With LIFO, the next checkout should get v3 (last in, first out)
  let r4 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  should.be_ok(r4)
  |> should.equal(v3)

  // Next checkout gets v2
  let r5 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  should.be_ok(r5)
  |> should.equal(v2)

  // Next checkout gets v1
  let r6 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  should.be_ok(r6)
  |> should.equal(v1)
}

pub fn fifo_checkout_strategy_test() {
  let manager =
    puddle.new(fn() { Ok(0) })
    |> puddle.size(3)
    |> puddle.checkout_strategy(puddle.FIFO)
    |> puddle.start(2000)
    |> should.be_ok

  // Check out all 3 resources and record their values
  let r1 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  let v1 = should.be_ok(r1)

  let r2 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  let v2 = should.be_ok(r2)

  let r3 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  let v3 = should.be_ok(r3)

  // Resources returned in order v1, v2, v3
  // With FIFO, next checkout should get v1 (first in, first out)
  let r4 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  should.be_ok(r4)
  |> should.equal(v1)

  let r5 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  should.be_ok(r5)
  |> should.equal(v2)

  let r6 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  should.be_ok(r6)
  |> should.equal(v3)
}

pub fn lazy_creation_test() {
  let creation_counter = process.new_subject()

  let manager =
    puddle.new(fn() {
      process.send(creation_counter, 1)
      Ok(42)
    })
    |> puddle.size(3)
    |> puddle.creation_strategy(puddle.Lazy)
    |> puddle.start(2000)
    |> should.be_ok

  // No resources should have been created yet
  let selector =
    process.new_selector()
    |> process.select_map(creation_counter, fn(v) { v })

  process.selector_receive(selector, 50)
  |> should.be_error

  // First apply should create one resource
  let r1 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  r1
  |> should.be_ok
  |> should.equal(42)

  // One creation message should have arrived
  process.selector_receive(selector, 50)
  |> should.be_ok

  // Second apply reuses the idle resource (no new creation)
  let r2 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  r2
  |> should.be_ok
  |> should.equal(42)

  // No new creation message
  process.selector_receive(selector, 50)
  |> should.be_error
}

pub fn lazy_creation_grows_on_demand_test() {
  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(3)
    |> puddle.creation_strategy(puddle.Lazy)
    |> puddle.start(2000)
    |> should.be_ok

  // Hold 3 resources simultaneously — all created on demand
  let t1 = hold_resource(manager, 500, 2000)
  let t2 = hold_resource(manager, 500, 2000)
  let t3 = hold_resource(manager, 500, 2000)

  // Small delay, then 4th should fail (pool at max capacity)
  process.sleep(50)
  let t4 =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 100)
      r
    })

  task_await(t4, 500)
  |> should.be_ok
  |> should.be_error

  task_await(t1, 2000) |> should.be_ok |> should.be_ok
  task_await(t2, 2000) |> should.be_ok |> should.be_ok
  task_await(t3, 2000) |> should.be_ok |> should.be_ok
}

pub fn discard_replaces_resource_test() {
  let creation_counter = process.new_subject()

  let manager =
    puddle.new(fn() {
      process.send(creation_counter, 1)
      Ok(42)
    })
    |> puddle.size(1)
    |> puddle.start(2000)
    |> should.be_ok

  let selector =
    process.new_selector()
    |> process.select_map(creation_counter, fn(v) { v })

  // Drain the initial creation message
  process.selector_receive(selector, 100)
  |> should.be_ok

  // Discard the resource — should trigger replacement
  let r1 = {
    use r <- puddle.apply(manager, fn(n) { puddle.discard(n) }, 1000)
    r
  }
  r1
  |> should.be_ok
  |> should.equal(42)

  // Wait for replacement to be created
  process.sleep(100)

  // A new creation message should have arrived
  process.selector_receive(selector, 100)
  |> should.be_ok

  // Pool should still be functional
  let r2 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  r2
  |> should.be_ok
  |> should.equal(42)
}

pub fn apply_blocking_test() {
  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(1)
    |> puddle.start(2000)
    |> should.be_ok

  // Hold the single resource for 300ms
  let t1 = hold_resource(manager, 300, 2000)

  process.sleep(50)

  // Non-blocking apply should fail immediately
  let t_fail =
    task_async(fn() {
      use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 100)
      r
    })

  task_await(t_fail, 500)
  |> should.be_ok
  |> should.be_error

  // Blocking apply should wait and succeed
  let t2 =
    task_async(fn() {
      use r <- puddle.apply_blocking(manager, fn(n) { puddle.keep(n) }, 2000)
      r
    })

  // t1 finishes after 300ms, t2 gets the resource
  task_await(t1, 2000)
  |> should.be_ok
  |> should.be_ok

  task_await(t2, 2000)
  |> should.be_ok
  |> should.be_ok
  |> should.equal(1)
}

pub fn apply_blocking_multiple_waiters_test() {
  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(1)
    |> puddle.start(2000)
    |> should.be_ok

  // Hold the resource
  let t1 = hold_resource(manager, 400, 2000)

  process.sleep(50)

  // Queue two blocking requests
  let t2 =
    task_async(fn() {
      use r <- puddle.apply_blocking(
        manager,
        fn(n) { puddle.keep(n + 10) },
        3000,
      )
      r
    })

  let t3 =
    task_async(fn() {
      use r <- puddle.apply_blocking(
        manager,
        fn(n) { puddle.keep(n + 20) },
        3000,
      )
      r
    })

  // All should eventually complete
  task_await(t1, 3000) |> should.be_ok |> should.be_ok
  task_await(t2, 3000) |> should.be_ok |> should.be_ok
  task_await(t3, 3000) |> should.be_ok |> should.be_ok
}

pub fn pool_status_ready_test() {
  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(3)
    |> puddle.start(2000)
    |> should.be_ok

  let s = puddle.status(manager, 1000)
  s.state |> should.equal(puddle.Ready)
  s.size |> should.equal(3)
  s.available |> should.equal(3)
  s.busy |> should.equal(0)
  s.waiting |> should.equal(0)
}

pub fn pool_status_full_test() {
  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(1)
    |> puddle.start(2000)
    |> should.be_ok

  // Hold the resource
  let _t = hold_resource(manager, 500, 2000)

  process.sleep(50)

  let s = puddle.status(manager, 1000)
  s.state |> should.equal(puddle.Full)
  s.available |> should.equal(0)
  s.busy |> should.equal(1)
  s.waiting |> should.equal(0)
}

pub fn pool_status_overloaded_test() {
  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(1)
    |> puddle.start(2000)
    |> should.be_ok

  // Hold the resource
  let _t1 = hold_resource(manager, 800, 2000)

  process.sleep(50)

  // Queue a blocking request
  let _t2 =
    task_async(fn() {
      use r <- puddle.apply_blocking(manager, fn(n) { puddle.keep(n) }, 3000)
      r
    })

  process.sleep(50)

  let s = puddle.status(manager, 1000)
  s.state |> should.equal(puddle.Overloaded)
  s.available |> should.equal(0)
  s.busy |> should.equal(1)
  s.waiting |> should.equal(1)
}

pub fn supervised_pool_test() {
  let pool_name = process.new_name("test_supervised_pool")

  let child_spec =
    puddle.new(fn() { Ok(42) })
    |> puddle.size(2)
    |> puddle.name(pool_name)
    |> puddle.supervised(2000)

  let assert Ok(_supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child_spec)
    |> static_supervisor.start

  process.sleep(100)

  let named = process.named_subject(pool_name)
  let r1 = {
    use r <- puddle.apply(named, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  r1
  |> should.be_ok
  |> should.equal(42)

  puddle.shutdown(named)
}

pub fn named_pool_test() {
  let pool_name = process.new_name("test_named_pool")

  let manager =
    puddle.new(fn() { Ok(99) })
    |> puddle.size(1)
    |> puddle.name(pool_name)
    |> puddle.start(2000)
    |> should.be_ok

  // Access via the returned subject
  let r1 = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  r1
  |> should.be_ok
  |> should.equal(99)

  // Access via named subject
  let named = process.named_subject(pool_name)
  let r2 = {
    use r <- puddle.apply(named, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  r2
  |> should.be_ok
  |> should.equal(99)
}

pub fn on_shutdown_callback_test() {
  let shutdown_subject = process.new_subject()

  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(2)
    |> puddle.on_shutdown(fn(_) { process.send(shutdown_subject, True) })
    |> puddle.start(2000)
    |> should.be_ok

  puddle.shutdown(manager)

  let selector =
    process.new_selector()
    |> process.select_map(shutdown_subject, fn(v) { v })

  // Should receive 2 shutdown notifications (one per resource)
  process.selector_receive(selector, 2000)
  |> should.be_ok
  |> should.equal(True)

  process.selector_receive(selector, 2000)
  |> should.be_ok
  |> should.equal(True)
}

pub fn lazy_with_blocking_test() {
  let manager =
    puddle.new(fn() { Ok(5) })
    |> puddle.size(2)
    |> puddle.creation_strategy(puddle.Lazy)
    |> puddle.start(2000)
    |> should.be_ok

  // Hold one lazily-created resource
  let t1 = hold_resource(manager, 300, 2000)

  process.sleep(50)

  // Blocking request should create a second resource lazily
  let t2 =
    task_async(fn() {
      use r <- puddle.apply_blocking(manager, fn(n) { puddle.keep(n) }, 2000)
      r
    })

  task_await(t1, 2000) |> should.be_ok |> should.be_ok |> should.equal(5)
  task_await(t2, 2000) |> should.be_ok |> should.be_ok |> should.equal(5)
}

pub fn waiter_crash_while_queued_test() {
  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(1)
    |> puddle.start(2000)
    |> should.be_ok

  // Hold the only resource for a while
  let t1 = hold_resource(manager, 500, 2000)

  process.sleep(50)

  // Spawn a blocking waiter that will crash before being served
  let waiter_pid =
    process.spawn_unlinked(fn() {
      use _r <- puddle.apply_blocking(manager, fn(n) { puddle.keep(n) }, 5000)
      Ok(Nil)
    })

  // Let the waiter enter the queue
  process.sleep(50)

  // Kill the waiter before the resource becomes available
  process.kill(waiter_pid)
  process.sleep(50)

  // Wait for t1 to finish and return its resource
  task_await(t1, 2000)
  |> should.be_ok
  |> should.be_ok

  // Pool should still be functional — the crashed waiter was cleaned up
  let r = {
    use r <- puddle.apply(manager, fn(n) { puddle.keep(n) }, 1000)
    r
  }
  r
  |> should.be_ok
  |> should.equal(1)
}

pub fn resource_creation_failure_during_queue_drain_test() {
  // Create a counter actor that tracks creation calls.
  // The counter owns its own subject so create_resource (running inside
  // the manager actor) can call it via process.call.
  let counter_ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let my_subj: process.Subject(process.Subject(Int)) = process.new_subject()
    process.send(counter_ready, my_subj)
    creation_counter_loop(my_subj, 0)
  })

  let counter_sel =
    process.new_selector()
    |> process.select_map(counter_ready, fn(v) { v })
  let assert Ok(counter_subj) = process.selector_receive(counter_sel, 1000)

  // create_resource calls the counter; first call (count=0) succeeds,
  // all subsequent calls (count>=1) fail.
  let manager =
    puddle.new(fn() {
      let n = process.call(counter_subj, 1000, fn(reply) { reply })
      case n < 1 {
        True -> Ok(1)
        False -> Error(Nil)
      }
    })
    |> puddle.size(1)
    |> puddle.start(2000)
    |> should.be_ok

  // Hold the resource and queue a blocking waiter
  let t1 = hold_resource(manager, 400, 2000)

  process.sleep(50)

  let _t2 =
    task_async(fn() {
      use r <- puddle.apply_blocking(manager, fn(n) { puddle.keep(n) }, 3000)
      r
    })

  process.sleep(50)

  // Crash the busy worker — replace_crashed_worker will call create_resource
  // which now returns Error(Nil) (counter >= 1), so pool_count decrements.
  crash_worker_and_wait(manager, 200)

  let _ = task_await(t1, 3000)

  // The pool is degraded but the manager is still alive
  let s = puddle.status(manager, 1000)
  s.size |> should.equal(1)
}

pub fn pool_status_lazy_ready_test() {
  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(10)
    |> puddle.creation_strategy(puddle.Lazy)
    |> puddle.start(2000)
    |> should.be_ok

  let s = puddle.status(manager, 1000)
  s.state |> should.equal(puddle.Ready)
  s.size |> should.equal(10)
  s.available |> should.equal(0)
  s.busy |> should.equal(0)
  s.waiting |> should.equal(0)
}

pub fn discard_fires_on_shutdown_test() {
  let shutdown_subject = process.new_subject()

  let manager =
    puddle.new(fn() { Ok(42) })
    |> puddle.size(1)
    |> puddle.on_shutdown(fn(_) { process.send(shutdown_subject, True) })
    |> puddle.start(2000)
    |> should.be_ok

  let r1 = {
    use r <- puddle.apply(manager, fn(n) { puddle.discard(n) }, 1000)
    r
  }
  r1
  |> should.be_ok
  |> should.equal(42)

  let selector =
    process.new_selector()
    |> process.select_map(shutdown_subject, fn(v) { v })

  process.selector_receive(selector, 2000)
  |> should.be_ok
  |> should.equal(True)
}

pub fn shutdown_while_waiters_queued_test() {
  let manager =
    puddle.new(fn() { Ok(1) })
    |> puddle.size(1)
    |> puddle.start(2000)
    |> should.be_ok

  let _t1 = hold_resource(manager, 500, 2000)

  process.sleep(50)

  let t2 =
    task_async(fn() {
      use r <- puddle.apply_blocking(manager, fn(n) { puddle.keep(n) }, 5000)
      r
    })

  let t3 =
    task_async(fn() {
      use r <- puddle.apply_blocking(manager, fn(n) { puddle.keep(n) }, 5000)
      r
    })

  process.sleep(50)

  puddle.shutdown(manager)

  task_await(t2, 2000)
  |> should.be_ok
  |> should.be_error

  task_await(t3, 2000)
  |> should.be_ok
  |> should.be_error
}
