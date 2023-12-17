import gleam/dict
import gleam/list
import gleam/result
import gleam/function
import gleam/otp/actor
import gleam/erlang/process

pub opaque type ManagerMessage(resource_type, result_type) {
  CheckIn(process.Pid)
  ProcessDown(process.ProcessDown)
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
    monitor: process.ProcessMonitor,
    subject: process.Subject(ResourceMessage(resource_type, result_type)),
  )
}

type BusyWorker(resource_type, result_type) {
  BusyWorker(
    pid: process.Pid,
    user_monitor: process.ProcessMonitor,
    worker_monitor: process.ProcessMonitor,
    subject: process.Subject(ResourceMessage(resource_type, result_type)),
  )
}

type Puddle(resource_type, result_type) {
  Puddle(
    selector: process.Selector(ManagerMessage(resource_type, result_type)),
    create_resource: fn() -> Result(resource_type, Nil),
    idle: dict.Dict(process.Pid, IdleWorker(resource_type, result_type)),
    busy: dict.Dict(process.Pid, BusyWorker(resource_type, result_type)),
  )
}

pub fn start(
  size: Int,
  create_resource: fn() -> Result(resource_type, Nil),
  timeout: Int,
) -> Result(
  process.Subject(ManagerMessage(resource_type, result_type)),
  actor.StartError,
) {
  actor.start_spec(actor.Spec(
    init: fn() {
      let selector = process.new_selector()

      case new(size, create_resource) {
        Ok(subjects) -> {
          let subjects =
            subjects
            |> list.map(fn(subject) {
              let pid = process.subject_owner(subject)
              #(pid, process.monitor_process(pid), subject)
            })

          let selector =
            list.fold(
              subjects,
              selector,
              fn(selector, subject) {
                process.selecting_process_down(
                  selector,
                  subject.1,
                  ProcessDown(_),
                )
              },
            )

          actor.Ready(
            Puddle(
              selector,
              create_resource,
              idle: list.map(
                subjects,
                fn(subject) { #(subject.0, IdleWorker(subject.1, subject.2)) },
              )
              |> dict.from_list,
              busy: dict.new(),
            ),
            selector,
          )
        }
        Error(Nil) -> actor.Failed("Failed to create resources")
      }
    },
    init_timeout: timeout,
    loop: handle_manager_message,
  ))
}

/// checks-out a resource, applies the function and then checks-in the resource
pub fn apply(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  fun: fn(resource_type) -> result_type,
  timeout: Int,
  rest,
) {
  use subject <- result.then(
    check_out(manager, timeout)
    |> result.replace_error(Nil)
    |> result.flatten,
  )

  let mine = process.new_subject()
  utilize(subject.1, fun, mine)

  let selector =
    process.selecting(process.new_selector(), mine, function.identity)

  let result =
    selector
    |> process.select(timeout)
    |> result.flatten

  check_in(manager, subject.0)
  rest(result)
}

pub fn shutdown(manager, shutdown_resource) {
  process.send(manager, ManagerShutdown(shutdown_resource))
}

fn check_out(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  timeout: Int,
) {
  process.try_call(manager, CheckOut(process.self(), _), timeout)
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

fn new(size: Int, create_resource: fn() -> Result(resource_type, Nil)) {
  list.repeat("", size)
  |> list.try_map(fn(_) {
    case create_resource() {
      Ok(initial_state) -> {
        actor.start(initial_state, handle_resource_message)
        |> result.nil_error()
      }
      Error(Nil) -> Error(Nil)
    }
  })
}

fn handle_manager_message(
  msg: ManagerMessage(resource_type, result_type),
  puddle: Puddle(resource_type, result_type),
) {
  case msg {
    ManagerShutdown(shutdown_resource) -> {
      list.each(
        puddle.idle
        |> dict.to_list
        |> list.map(fn(subject) {
          case subject.1 {
            IdleWorker(monitor, subject) -> {
              process.demonitor_process(monitor)
              subject
            }
          }
        }),
        process.send(_, ResourceShutdown(shutdown_resource)),
      )

      list.each(
        puddle.busy
        |> dict.to_list
        |> list.map(fn(subject) {
          case subject.1 {
            BusyWorker(_, user_monitor, worker_monitor, subject) -> {
              process.demonitor_process(user_monitor)
              process.demonitor_process(worker_monitor)
              subject
            }
          }
        }),
        process.send(_, ResourceShutdown(shutdown_resource)),
      )

      actor.Stop(process.Normal)
    }
    CheckIn(pid) -> {
      case dict.get(puddle.busy, pid) {
        Ok(BusyWorker(pid, user_monitor, worker_monitor, subject)) -> {
          process.demonitor_process(user_monitor)
          actor.continue(Puddle(
            puddle.selector,
            puddle.create_resource,
            idle: dict.insert(
              puddle.idle,
              pid,
              IdleWorker(worker_monitor, subject),
            ),
            busy: dict.drop(puddle.busy, [pid]),
          ))
        }

        Error(Nil) ->
          actor.continue(Puddle(
            puddle.selector,
            puddle.create_resource,
            idle: puddle.idle,
            busy: puddle.busy,
          ))
      }
    }
    CheckOut(pid, client) -> {
      case dict.to_list(puddle.idle) {
        [] -> {
          actor.send(client, Error(Nil))
          actor.continue(puddle)
        }

        [#(worker_pid, IdleWorker(worker_monitor, chosen)), ..new_idle] -> {
          actor.send(client, Ok(#(worker_pid, chosen)))
          let user_monitor = process.monitor_process(pid)

          let new_busy =
            dict.insert(
              puddle.busy,
              pid,
              BusyWorker(worker_pid, user_monitor, worker_monitor, chosen),
            )

          let selector =
            process.selecting_process_down(
              puddle.selector,
              user_monitor,
              ProcessDown(_),
            )

          actor.continue(Puddle(
            selector,
            puddle.create_resource,
            idle: dict.from_list(new_idle),
            busy: new_busy,
          ))
          |> actor.with_selector(selector)
        }
      }
    }

    ProcessDown(process.ProcessDown(pid, _)) -> {
      case dict.get(puddle.idle, pid) {
        Ok(_) -> {
          let idle = dict.drop(puddle.idle, [pid])

          case puddle.create_resource() {
            Ok(initial_state) -> {
              case actor.start(initial_state, handle_resource_message) {
                Ok(subject) -> {
                  let worker_pid = process.subject_owner(subject)
                  let worker_monitor = process.monitor_process(worker_pid)

                  let selector =
                    process.selecting_process_down(
                      puddle.selector,
                      worker_monitor,
                      ProcessDown(_),
                    )

                  actor.continue(Puddle(
                    selector,
                    puddle.create_resource,
                    dict.insert(
                      idle,
                      worker_pid,
                      IdleWorker(worker_monitor, subject),
                    ),
                    puddle.busy,
                  ))
                  |> actor.with_selector(selector)
                }
                Error(_) ->
                  actor.Stop(process.Abnormal(
                    "Unable to substitute crashed worker",
                  ))
              }
            }

            Error(Nil) ->
              actor.Stop(process.Abnormal("Unable to substitute crashed worker"))
          }
        }

        Error(Nil) ->
          case dict.get(puddle.busy, pid) {
            Ok(BusyWorker(pid, user_monitor, worker_monitor, subject)) -> {
              process.demonitor_process(user_monitor)
              let idle =
                dict.insert(
                  puddle.idle,
                  pid,
                  IdleWorker(worker_monitor, subject),
                )
              let busy = dict.drop(puddle.busy, [pid])
              actor.continue(Puddle(
                puddle.selector,
                puddle.create_resource,
                idle,
                busy,
              ))
            }
            Error(Nil) -> actor.continue(puddle)
          }
      }
    }
  }
}

fn handle_resource_message(
  msg: ResourceMessage(resource_type, result_type),
  resource: resource_type,
) {
  case msg {
    ResourceUsage(fun, client) -> {
      let result = fun(resource)
      actor.send(client, Ok(result))
      actor.continue(resource)
    }

    ResourceShutdown(shutdown) -> {
      shutdown(resource)
      actor.Stop(process.Normal)
    }
  }
}
