import gleam/dict
import gleam/erlang/process
import gleam/function
import gleam/list
import gleam/otp/actor
import gleam/result

/// A resource pool manager for Gleam.
///
/// `puddle` manages a fixed-size pool of reusable resources (workers), each holding
/// a single resource instance. It handles check-out/check-in, automatic crash recovery,
/// and backpressure when the pool is exhausted.
///
/// ## Quick Start
///
/// ```gleam
/// import gleam/int
/// import gleam/io
/// import puddle
///
/// pub fn main() {
///   let assert Ok(manager) = puddle.start(4, fn() { Ok(int.random(8192)) }, 1000)
///
///   let result = {
///     use r <- puddle.apply(manager, fn(n) { n * 2 }, 1000)
///     r
///   }
///   io.debug(result) // Ok(16384)
/// }
/// ```
///
/// ## Resource Lifecycle
///
/// 1. **Creation**: `start` spawns `size` workers, each calling `create_resource`
/// 2. **Check-out**: `apply` acquires an idle worker exclusively
/// 3. **Execution**: User function runs with the resource
/// 4. **Check-in**: Resource returned to idle pool automatically (via `use` syntax)
/// 5. **Shutdown**: `shutdown` gracefully stops all workers
///
/// ## Crash Recovery
///
/// - **Idle worker crash**: Replaced automatically, pool size maintained
/// - **Busy worker crash**: Replaced automatically; caller receives `Error(Nil)`
/// - **User process crash**: Resource returned to pool automatically
///
/// ## Concurrency
///
/// - Multiple processes can call `apply` concurrently
/// - Same process can reuse the pool sequentially
/// - Pool exhaustion returns `Error(Nil)` immediately (no queueing)
///
/// See `puddle_test.gleam` for usage patterns and edge cases.
pub opaque type ManagerMessage(resource_type, result_type) {
  CheckIn(process.Pid)
  ProcessDown(process.Down)
  ManagerShutdown(fn(resource_type) -> Nil)
  CheckOut(
    process.Pid,
    process.Subject(
      Result(
        #(
          process.Pid,
          process.Subject(ResourceMessage(resource_type, result_type)),
        ),
        Nil,
      ),
    ),
  )
}

pub opaque type ResourceMessage(resource_type, result_type) {
  ResourceShutdown(fn(resource_type) -> Nil)
  ResourceUsage(
    fn(resource_type) -> result_type,
    process.Subject(Result(result_type, Nil)),
  )
}

type IdleWorker(resource_type, result_type) {
  IdleWorker(
    monitor: process.Monitor,
    subject: process.Subject(ResourceMessage(resource_type, result_type)),
  )
}

type BusyEntry(resource_type, result_type) {
  BusyEntry(
    user_pid: process.Pid,
    user_monitor: process.Monitor,
    worker_monitor: process.Monitor,
    subject: process.Subject(ResourceMessage(resource_type, result_type)),
  )
}

type Puddle(resource_type, result_type) {
  Puddle(
    selector: process.Selector(ManagerMessage(resource_type, result_type)),
    create_resource: fn() -> Result(resource_type, Nil),
    idle: dict.Dict(process.Pid, IdleWorker(resource_type, result_type)),
    busy_by_worker: dict.Dict(
      process.Pid,
      BusyEntry(resource_type, result_type),
    ),
    busy_by_user: dict.Dict(process.Pid, process.Pid),
  )
}

/// Starts a new resource pool with the given size.
///
/// Each worker is initialized by calling `create_resource`. If any worker fails to
/// initialize, the entire pool startup fails and returns `Error(actor.StartError)`.
///
/// ### Parameters
/// - `size`: Number of workers in the pool (fixed for the pool's lifetime)
/// - `create_resource`: Function that creates a resource instance.
///   Return `Ok(resource)` on success, `Error(Nil)` on failure.
/// - `timeout`: Milliseconds to wait for pool initialization.
///
/// ### Returns
/// `Ok(manager_subject)` on success, `Error(actor.StartError)` on failure.
///
/// ### Example
/// ```gleam
/// let assert Ok(pool) = puddle.start(10, fn() { connect_to_db() }, 5000)
/// ```
pub fn start(
  size: Int,
  create_resource: fn() -> Result(resource_type, Nil),
  timeout: Int,
) -> Result(
  process.Subject(ManagerMessage(resource_type, result_type)),
  actor.StartError,
) {
  actor.new_with_initialiser(timeout, fn(default_subject) {
    let selector =
      process.new_selector()
      |> process.select(default_subject)

    case new(size, create_resource) {
      Ok(workers) -> {
        let selector =
          list.fold(workers, selector, fn(selector, worker) {
            process.select_specific_monitor(selector, worker.1, ProcessDown)
          })

        Ok(
          actor.initialised(Puddle(
            selector,
            create_resource,
            idle: list.map(workers, fn(worker) {
              #(worker.0, IdleWorker(worker.1, worker.2))
            })
              |> dict.from_list,
            busy_by_worker: dict.new(),
            busy_by_user: dict.new(),
          ))
          |> actor.selecting(selector)
          |> actor.returning(default_subject),
        )
      }
      Error(Nil) -> Error("Failed to create resources")
    }
  })
  |> actor.on_message(handle_manager_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// Checks out a resource, applies `fun`, and checks the resource back in.
///
/// Uses Gleam's `use` syntax for automatic check-in. The resource is returned to
/// the idle pool when the `use` block exits (normally or via error).
///
/// ### Parameters
/// - `manager`: Pool manager returned by `start`
/// - `fun`: Function receiving the resource, returning a result
/// - `timeout`: Milliseconds to wait for check-out AND function execution
///
/// ### Returns
/// `Result(result_type, Nil)` via continuation. Returns `Error(Nil)` if:
/// - No idle workers available (pool exhausted)
/// - Check-out times out
/// - Function execution times out
/// - Worker crashes during execution
///
/// ### Example
/// ```gleam
/// let result = {
///   use conn <- puddle.apply(pool, fn(c) { query(c, "SELECT * FROM users") }, 2000)
///   conn
/// }
/// // result = Ok("...") or Error(Nil)
/// ```
pub fn apply(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  fun: fn(resource_type) -> result_type,
  timeout: Int,
  rest,
) {
  use subject <- result.try(check_out(manager, timeout))

  let mine = process.new_subject()
  utilize(subject.1, fun, mine)

  let selector =
    process.select_map(process.new_selector(), mine, function.identity)

  let result =
    selector
    |> process.selector_receive(timeout)
    |> result.flatten

  check_in(manager, subject.0)
  rest(result)
}

/// Gracefully shuts down the pool.
///
/// Sends a shutdown signal to the manager. The manager will:
/// 1. Immediately shut down all idle workers (calling `shutdown_resource`)
/// 2. Wait for busy workers to complete their current `apply`, then shut them down
/// 3. Stop the manager actor
///
/// ### Parameters
/// - `manager`: Pool manager from `start`
/// - `shutdown_resource`: Function to clean up a resource (e.g., close connection)
///
/// ### Example
/// ```gleam
/// puddle.shutdown(pool, fn(DbConnection(host, port)) {
///   close_connection(host, port)
/// })
/// ```
pub fn shutdown(manager, shutdown_resource) {
  process.send(manager, ManagerShutdown(shutdown_resource))
}

fn check_out(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  timeout: Int,
) {
  process.call(manager, timeout, CheckOut(process.self(), _))
}

fn utilize(
  subject: process.Subject(ResourceMessage(resource_type, result_type)),
  fun: fn(resource_type) -> result_type,
  mine: process.Subject(Result(result_type, Nil)),
) {
  process.send(subject, ResourceUsage(fun, mine))
}

fn check_in(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  subject_pid: process.Pid,
) {
  process.send(manager, CheckIn(subject_pid))
}

fn create_single_worker(
  create_resource: fn() -> Result(resource_type, Nil),
) -> Result(
  #(
    process.Pid,
    process.Monitor,
    process.Subject(ResourceMessage(resource_type, result_type)),
  ),
  Nil,
) {
  case create_resource() {
    Ok(initial_state) -> {
      case
        actor.new(initial_state)
        |> actor.on_message(handle_resource_message)
        |> actor.start
      {
        Ok(started) -> {
          let subject = started.data
          let assert Ok(pid) = process.subject_owner(subject)
          process.unlink(pid)
          let monitor = process.monitor(pid)
          Ok(#(pid, monitor, subject))
        }
        Error(_) -> Error(Nil)
      }
    }
    Error(Nil) -> Error(Nil)
  }
}

fn new(size: Int, create_resource: fn() -> Result(resource_type, Nil)) {
  list.repeat(Nil, size)
  |> list.try_map(fn(_) { create_single_worker(create_resource) })
}

fn move_to_idle(
  puddle: Puddle(resource_type, result_type),
  worker_pid: process.Pid,
  worker_monitor: process.Monitor,
  subject: process.Subject(ResourceMessage(resource_type, result_type)),
) -> Puddle(resource_type, result_type) {
  Puddle(
    ..puddle,
    idle: dict.insert(
      puddle.idle,
      worker_pid,
      IdleWorker(worker_monitor, subject),
    ),
  )
}

fn move_to_busy(
  puddle: Puddle(resource_type, result_type),
  worker_pid: process.Pid,
  user_pid: process.Pid,
  user_monitor: process.Monitor,
  worker_monitor: process.Monitor,
  subject: process.Subject(ResourceMessage(resource_type, result_type)),
) -> Puddle(resource_type, result_type) {
  Puddle(
    ..puddle,
    busy_by_worker: dict.insert(
      puddle.busy_by_worker,
      worker_pid,
      BusyEntry(user_pid, user_monitor, worker_monitor, subject),
    ),
    busy_by_user: dict.insert(puddle.busy_by_user, user_pid, worker_pid),
  )
}

fn remove_busy_entry(
  puddle: Puddle(resource_type, result_type),
  worker_pid: process.Pid,
  user_pid: process.Pid,
) -> Puddle(resource_type, result_type) {
  Puddle(
    ..puddle,
    busy_by_worker: dict.drop(puddle.busy_by_worker, [worker_pid]),
    busy_by_user: dict.drop(puddle.busy_by_user, [user_pid]),
  )
}

fn replace_crashed_worker(
  puddle: Puddle(resource_type, result_type),
  idle: dict.Dict(process.Pid, IdleWorker(resource_type, result_type)),
) {
  case create_single_worker(puddle.create_resource) {
    Ok(#(worker_pid, worker_monitor, subject)) -> {
      let selector =
        process.select_specific_monitor(
          puddle.selector,
          worker_monitor,
          ProcessDown,
        )

      actor.continue(Puddle(
        selector,
        puddle.create_resource,
        idle: dict.insert(idle, worker_pid, IdleWorker(worker_monitor, subject)),
        busy_by_worker: puddle.busy_by_worker,
        busy_by_user: puddle.busy_by_user,
      ))
      |> actor.with_selector(selector)
    }
    Error(Nil) -> actor.stop_abnormal("Unable to substitute crashed worker")
  }
}

fn handle_manager_message(
  puddle: Puddle(resource_type, result_type),
  msg: ManagerMessage(resource_type, result_type),
) {
  case msg {
    ManagerShutdown(shutdown_resource) -> {
      list.each(
        puddle.idle
          |> dict.to_list
          |> list.map(fn(entry) {
            case entry.1 {
              IdleWorker(monitor, subject) -> {
                process.demonitor_process(monitor)
                subject
              }
            }
          }),
        process.send(_, ResourceShutdown(shutdown_resource)),
      )

      list.each(
        puddle.busy_by_worker
          |> dict.to_list
          |> list.map(fn(entry) {
            case entry.1 {
              BusyEntry(_user_pid, user_monitor, worker_monitor, subject) -> {
                process.demonitor_process(user_monitor)
                process.demonitor_process(worker_monitor)
                subject
              }
            }
          }),
        process.send(_, ResourceShutdown(shutdown_resource)),
      )

      actor.stop()
    }

    CheckIn(worker_pid) -> {
      case dict.get(puddle.busy_by_worker, worker_pid) {
        Ok(BusyEntry(user_pid, user_monitor, worker_monitor, subject)) -> {
          process.demonitor_process(user_monitor)
          let puddle = remove_busy_entry(puddle, worker_pid, user_pid)
          actor.continue(move_to_idle(
            puddle,
            worker_pid,
            worker_monitor,
            subject,
          ))
        }

        Error(Nil) -> actor.continue(puddle)
      }
    }

    CheckOut(user_pid, client) -> {
      case dict.to_list(puddle.idle) {
        [] -> {
          actor.send(client, Error(Nil))
          actor.continue(puddle)
        }

        [#(worker_pid, IdleWorker(worker_monitor, chosen)), ..new_idle] -> {
          actor.send(client, Ok(#(worker_pid, chosen)))
          let user_monitor = process.monitor(user_pid)

          let selector =
            process.select_specific_monitor(
              puddle.selector,
              user_monitor,
              ProcessDown,
            )

          let puddle =
            move_to_busy(
              Puddle(
                ..puddle,
                selector: selector,
                idle: dict.from_list(new_idle),
              ),
              worker_pid,
              user_pid,
              user_monitor,
              worker_monitor,
              chosen,
            )

          actor.continue(puddle)
          |> actor.with_selector(selector)
        }
      }
    }

    ProcessDown(process.ProcessDown(_, down_pid, _)) -> {
      // Case 1: idle worker crashed
      case dict.get(puddle.idle, down_pid) {
        Ok(_) -> {
          let idle = dict.drop(puddle.idle, [down_pid])
          replace_crashed_worker(puddle, idle)
        }

        Error(Nil) ->
          // Case 2: busy worker crashed
          case dict.get(puddle.busy_by_worker, down_pid) {
            Ok(BusyEntry(user_pid, user_monitor, _worker_monitor, _subject)) -> {
              process.demonitor_process(user_monitor)
              let puddle = remove_busy_entry(puddle, down_pid, user_pid)
              replace_crashed_worker(puddle, puddle.idle)
            }

            Error(Nil) ->
              // Case 3: user process crashed
              case dict.get(puddle.busy_by_user, down_pid) {
                Ok(worker_pid) -> {
                  let assert Ok(BusyEntry(
                    _user_pid,
                    user_monitor,
                    worker_monitor,
                    subject,
                  )) = dict.get(puddle.busy_by_worker, worker_pid)
                  process.demonitor_process(user_monitor)
                  let puddle = remove_busy_entry(puddle, worker_pid, down_pid)
                  actor.continue(move_to_idle(
                    puddle,
                    worker_pid,
                    worker_monitor,
                    subject,
                  ))
                }

                Error(Nil) -> actor.continue(puddle)
              }
          }
      }
    }

    ProcessDown(process.PortDown(_, _, _)) -> actor.continue(puddle)
  }
}

fn handle_resource_message(
  resource: resource_type,
  msg: ResourceMessage(resource_type, result_type),
) {
  case msg {
    ResourceUsage(fun, client) -> {
      let result = fun(resource)
      actor.send(client, Ok(result))
      actor.continue(resource)
    }

    ResourceShutdown(shutdown) -> {
      shutdown(resource)
      actor.stop()
    }
  }
}
