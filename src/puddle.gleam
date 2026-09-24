import gleam/dict
import gleam/erlang/process
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result

// --- Public types ---

pub type CheckoutStrategy {
  FIFO
  LIFO
}

pub type CreationStrategy {
  Lazy
  Eager
}

pub type Next(result_type) {
  Keep(result_type)
  Discard(result_type)
}

pub type PoolState {
  Ready
  Full
  Overloaded
}

pub type PoolStatus {
  PoolStatus(
    state: PoolState,
    size: Int,
    available: Int,
    busy: Int,
    waiting: Int,
  )
}

pub type ApplyError {
  NoResourcesAvailable
  CheckoutTimeout
  PoolShuttingDown
}

// --- Builder ---

pub opaque type Builder(resource_type, result_type) {
  Builder(
    create_resource: fn() -> Result(resource_type, Nil),
    size: Int,
    checkout_strategy: CheckoutStrategy,
    creation_strategy: CreationStrategy,
    on_shutdown: fn(resource_type) -> Nil,
    name: Option(process.Name(ManagerMessage(resource_type, result_type))),
  )
}

pub fn new(
  create_resource: fn() -> Result(resource_type, Nil),
) -> Builder(resource_type, result_type) {
  Builder(
    create_resource: create_resource,
    size: 10,
    checkout_strategy: FIFO,
    creation_strategy: Eager,
    on_shutdown: fn(_) { Nil },
    name: None,
  )
}

pub fn size(
  builder: Builder(resource_type, result_type),
  size: Int,
) -> Builder(resource_type, result_type) {
  Builder(..builder, size: size)
}

pub fn checkout_strategy(
  builder: Builder(resource_type, result_type),
  strategy: CheckoutStrategy,
) -> Builder(resource_type, result_type) {
  Builder(..builder, checkout_strategy: strategy)
}

pub fn creation_strategy(
  builder: Builder(resource_type, result_type),
  strategy: CreationStrategy,
) -> Builder(resource_type, result_type) {
  Builder(..builder, creation_strategy: strategy)
}

pub fn on_shutdown(
  builder: Builder(resource_type, result_type),
  callback: fn(resource_type) -> Nil,
) -> Builder(resource_type, result_type) {
  Builder(..builder, on_shutdown: callback)
}

pub fn name(
  builder: Builder(resource_type, result_type),
  pool_name: process.Name(ManagerMessage(resource_type, result_type)),
) -> Builder(resource_type, result_type) {
  Builder(..builder, name: Some(pool_name))
}

// --- Convenience constructors for Next ---

pub fn keep(value: result_type) -> Next(result_type) {
  Keep(value)
}

pub fn discard(value: result_type) -> Next(result_type) {
  Discard(value)
}

// --- Messages ---

pub opaque type ManagerMessage(resource_type, result_type) {
  CheckIn(process.Pid)
  DiscardWorker(process.Pid)
  ProcessDown(process.Down)
  ManagerShutdown
  GetStatus(process.Subject(PoolStatus))
  CheckOut(
    process.Pid,
    process.Subject(
      Result(
        #(
          process.Pid,
          process.Subject(ResourceMessage(resource_type, result_type)),
        ),
        ApplyError,
      ),
    ),
  )
  CheckOutBlocking(
    process.Pid,
    process.Subject(
      Result(
        #(
          process.Pid,
          process.Subject(ResourceMessage(resource_type, result_type)),
        ),
        ApplyError,
      ),
    ),
  )
}

pub opaque type ResourceMessage(resource_type, result_type) {
  ResourceShutdown(fn(resource_type) -> Nil)
  ResourceUsage(
    fn(resource_type) -> Next(result_type),
    process.Subject(Result(Next(result_type), Nil)),
  )
}

// --- Internal types ---

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

type WaitingEntry(resource_type, result_type) {
  WaitingEntry(
    user_pid: process.Pid,
    user_monitor: process.Monitor,
    client: process.Subject(
      Result(
        #(
          process.Pid,
          process.Subject(ResourceMessage(resource_type, result_type)),
        ),
        ApplyError,
      ),
    ),
  )
}

type Puddle(resource_type, result_type) {
  Puddle(
    selector: process.Selector(ManagerMessage(resource_type, result_type)),
    create_resource: fn() -> Result(resource_type, Nil),
    on_shutdown: fn(resource_type) -> Nil,
    checkout_strategy: CheckoutStrategy,
    creation_strategy: CreationStrategy,
    pool_size: Int,
    pool_count: Int,
    idle: dict.Dict(process.Pid, IdleWorker(resource_type, result_type)),
    idle_order: List(process.Pid),
    busy_by_worker: dict.Dict(
      process.Pid,
      BusyEntry(resource_type, result_type),
    ),
    busy_by_user: dict.Dict(process.Pid, process.Pid),
    waiting: List(WaitingEntry(resource_type, result_type)),
  )
}

// --- Public API ---

pub fn start(
  builder: Builder(resource_type, result_type),
  timeout: Int,
) -> Result(
  process.Subject(ManagerMessage(resource_type, result_type)),
  actor.StartError,
) {
  build_actor(builder, timeout)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

pub fn supervised(
  builder: Builder(resource_type, result_type),
  timeout: Int,
) -> supervision.ChildSpecification(
  process.Subject(ManagerMessage(resource_type, result_type)),
) {
  supervision.worker(fn() {
    build_actor(builder, timeout)
    |> actor.start
  })
}

pub fn apply(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  fun: fn(resource_type) -> Next(result_type),
  timeout: Int,
  rest,
) {
  use subject <- result.try(check_out(manager, timeout))
  use_and_return(manager, subject, fun, timeout, rest)
}

pub fn apply_blocking(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  fun: fn(resource_type) -> Next(result_type),
  timeout: Int,
  rest,
) {
  use subject <- result.try(check_out_blocking(manager, timeout))
  use_and_return(manager, subject, fun, timeout, rest)
}

pub fn shutdown(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
) {
  process.send(manager, ManagerShutdown)
}

pub fn status(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  timeout: Int,
) -> PoolStatus {
  process.call(manager, timeout, GetStatus)
}

// --- Internal: actor construction ---

fn build_actor(builder: Builder(resource_type, result_type), timeout: Int) {
  let actor_builder =
    actor.new_with_initialiser(timeout, init_pool(builder, _))
    |> actor.on_message(handle_manager_message)

  case builder.name {
    Some(n) -> actor.named(actor_builder, n)
    None -> actor_builder
  }
}

fn init_pool(builder: Builder(resource_type, result_type), default_subject) {
  let selector =
    process.new_selector()
    |> process.select(default_subject)

  let initial_size = case builder.creation_strategy {
    Eager -> builder.size
    Lazy -> 0
  }

  case create_workers(initial_size, builder.create_resource) {
    Ok(workers) -> {
      let selector =
        list.fold(workers, selector, fn(sel, worker) {
          process.select_specific_monitor(sel, worker.1, ProcessDown)
        })

      let idle_pids = list.map(workers, fn(worker) { worker.0 })

      Ok(
        actor.initialised(
          Puddle(
            selector: selector,
            create_resource: builder.create_resource,
            on_shutdown: builder.on_shutdown,
            checkout_strategy: builder.checkout_strategy,
            creation_strategy: builder.creation_strategy,
            pool_size: builder.size,
            pool_count: initial_size,
            idle: list.map(workers, fn(worker) {
              #(worker.0, IdleWorker(worker.1, worker.2))
            })
              |> dict.from_list,
            idle_order: idle_pids,
            busy_by_worker: dict.new(),
            busy_by_user: dict.new(),
            waiting: [],
          ),
        )
        |> actor.selecting(selector)
        |> actor.returning(default_subject),
      )
    }
    Error(Nil) -> Error("Failed to create resources")
  }
}

// --- Internal: checkout and resource usage ---

fn check_out(manager, timeout) {
  process.call(manager, timeout, CheckOut(process.self(), _))
}

fn check_out_blocking(manager, timeout) {
  process.call(manager, timeout, CheckOutBlocking(process.self(), _))
}

fn use_and_return(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  subject: #(
    process.Pid,
    process.Subject(ResourceMessage(resource_type, result_type)),
  ),
  fun: fn(resource_type) -> Next(result_type),
  timeout: Int,
  rest,
) {
  let mine = process.new_subject()
  process.send(subject.1, ResourceUsage(fun, mine))

  let selector =
    process.select_map(process.new_selector(), mine, function.identity)

  case process.selector_receive(selector, timeout) |> result.flatten {
    Ok(Keep(value)) -> {
      check_in(manager, subject.0)
      rest(Ok(value))
    }
    Ok(Discard(value)) -> {
      discard_worker(manager, subject.0)
      rest(Ok(value))
    }
    Error(Nil) -> {
      check_in(manager, subject.0)
      rest(Error(CheckoutTimeout))
    }
  }
}

fn check_in(manager, worker_pid) {
  process.send(manager, CheckIn(worker_pid))
}

fn discard_worker(manager, worker_pid) {
  process.send(manager, DiscardWorker(worker_pid))
}

// --- Internal: worker lifecycle ---

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

fn create_workers(size, create_resource) {
  list.repeat(Nil, size)
  |> list.try_map(fn(_) { create_single_worker(create_resource) })
}

// --- Internal: state transition helpers ---

fn add_to_idle(
  puddle: Puddle(resource_type, result_type),
  worker_pid: process.Pid,
  worker_monitor: process.Monitor,
  subject: process.Subject(ResourceMessage(resource_type, result_type)),
) {
  let idle_order = case puddle.checkout_strategy {
    FIFO -> list.append(puddle.idle_order, [worker_pid])
    LIFO -> [worker_pid, ..puddle.idle_order]
  }
  Puddle(
    ..puddle,
    idle: dict.insert(
      puddle.idle,
      worker_pid,
      IdleWorker(worker_monitor, subject),
    ),
    idle_order: idle_order,
  )
}

fn remove_from_idle(
  puddle: Puddle(resource_type, result_type),
  worker_pid: process.Pid,
) {
  Puddle(
    ..puddle,
    idle: dict.drop(puddle.idle, [worker_pid]),
    idle_order: list.filter(puddle.idle_order, fn(pid) { pid != worker_pid }),
  )
}

fn move_to_busy(
  puddle: Puddle(resource_type, result_type),
  worker_pid: process.Pid,
  user_pid: process.Pid,
  user_monitor: process.Monitor,
  worker_monitor: process.Monitor,
  subject: process.Subject(ResourceMessage(resource_type, result_type)),
) {
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
) {
  Puddle(
    ..puddle,
    busy_by_worker: dict.drop(puddle.busy_by_worker, [worker_pid]),
    busy_by_user: dict.drop(puddle.busy_by_user, [user_pid]),
  )
}

fn replace_crashed_worker(puddle: Puddle(resource_type, result_type)) {
  case create_single_worker(puddle.create_resource) {
    Ok(#(worker_pid, worker_monitor, subject)) -> {
      let selector =
        process.select_specific_monitor(
          puddle.selector,
          worker_monitor,
          ProcessDown,
        )

      let puddle = Puddle(..puddle, selector: selector)
      let puddle = serve_or_idle(puddle, worker_pid, worker_monitor, subject)

      actor.continue(puddle)
      |> actor.with_selector(puddle.selector)
    }
    Error(Nil) -> {
      let puddle = Puddle(..puddle, pool_count: puddle.pool_count - 1)
      actor.continue(puddle)
    }
  }
}

fn serve_or_idle(
  puddle: Puddle(resource_type, result_type),
  worker_pid: process.Pid,
  worker_monitor: process.Monitor,
  subject: process.Subject(ResourceMessage(resource_type, result_type)),
) {
  case puddle.waiting {
    [] -> add_to_idle(puddle, worker_pid, worker_monitor, subject)
    [WaitingEntry(user_pid, user_monitor, client), ..rest] -> {
      actor.send(client, Ok(#(worker_pid, subject)))
      Puddle(..puddle, waiting: rest)
      |> move_to_busy(
        worker_pid,
        user_pid,
        user_monitor,
        worker_monitor,
        subject,
      )
    }
  }
}

fn try_lazy_create_and_checkout(
  puddle: Puddle(resource_type, result_type),
  user_pid: process.Pid,
  client: process.Subject(
    Result(
      #(
        process.Pid,
        process.Subject(ResourceMessage(resource_type, result_type)),
      ),
      ApplyError,
    ),
  ),
) {
  case create_single_worker(puddle.create_resource) {
    Ok(#(worker_pid, worker_monitor, subject)) -> {
      actor.send(client, Ok(#(worker_pid, subject)))
      let user_monitor = process.monitor(user_pid)

      let selector =
        puddle.selector
        |> process.select_specific_monitor(worker_monitor, ProcessDown)
        |> process.select_specific_monitor(user_monitor, ProcessDown)

      let puddle =
        Puddle(..puddle, selector: selector, pool_count: puddle.pool_count + 1)
        |> move_to_busy(
          worker_pid,
          user_pid,
          user_monitor,
          worker_monitor,
          subject,
        )

      actor.continue(puddle)
      |> actor.with_selector(selector)
    }
    Error(Nil) -> {
      actor.send(client, Error(NoResourcesAvailable))
      actor.continue(puddle)
    }
  }
}

fn remove_waiting_by_pid(
  puddle: Puddle(resource_type, result_type),
  pid: process.Pid,
) {
  let waiting =
    list.filter(puddle.waiting, fn(entry) {
      case entry.user_pid == pid {
        True -> {
          process.demonitor_process(entry.user_monitor)
          False
        }
        False -> True
      }
    })
  Puddle(..puddle, waiting: waiting)
}

fn has_lazy_capacity(puddle: Puddle(resource_type, result_type)) -> Bool {
  puddle.creation_strategy == Lazy && puddle.pool_count < puddle.pool_size
}

fn checkout_idle_worker(
  puddle: Puddle(resource_type, result_type),
  worker_pid: process.Pid,
  user_pid: process.Pid,
  client: process.Subject(
    Result(
      #(
        process.Pid,
        process.Subject(ResourceMessage(resource_type, result_type)),
      ),
      ApplyError,
    ),
  ),
) {
  let assert Ok(IdleWorker(worker_monitor, chosen)) =
    dict.get(puddle.idle, worker_pid)
  actor.send(client, Ok(#(worker_pid, chosen)))
  let user_monitor = process.monitor(user_pid)

  let selector =
    process.select_specific_monitor(
      puddle.selector,
      user_monitor,
      ProcessDown,
    )

  let puddle = remove_from_idle(puddle, worker_pid)
  let puddle =
    move_to_busy(
      Puddle(..puddle, selector: selector),
      worker_pid,
      user_pid,
      user_monitor,
      worker_monitor,
      chosen,
    )

  actor.continue(puddle)
  |> actor.with_selector(selector)
}

// --- Manager message handler ---

fn handle_manager_message(
  puddle: Puddle(resource_type, result_type),
  msg: ManagerMessage(resource_type, result_type),
) {
  case msg {
    ManagerShutdown -> {
      list.each(
        puddle.idle
          |> dict.to_list
          |> list.map(fn(entry) {
            let IdleWorker(monitor, subject) = entry.1
            process.demonitor_process(monitor)
            subject
          }),
        process.send(_, ResourceShutdown(puddle.on_shutdown)),
      )

      list.each(
        puddle.busy_by_worker
          |> dict.to_list
          |> list.map(fn(entry) {
            let BusyEntry(_, user_monitor, worker_monitor, subject) = entry.1
            process.demonitor_process(user_monitor)
            process.demonitor_process(worker_monitor)
            subject
          }),
        process.send(_, ResourceShutdown(puddle.on_shutdown)),
      )

      list.each(puddle.waiting, fn(entry) {
        process.demonitor_process(entry.user_monitor)
        actor.send(entry.client, Error(PoolShuttingDown))
      })

      actor.stop()
    }

    GetStatus(client) -> {
      let available = dict.size(puddle.idle)
      let busy_count = dict.size(puddle.busy_by_worker)
      let waiting_count = list.length(puddle.waiting)
      let state = case available, waiting_count {
        0, w if w > 0 -> Overloaded
        0, _ ->
          case has_lazy_capacity(puddle) {
            True -> Ready
            False -> Full
          }
        _, _ -> Ready
      }
      actor.send(
        client,
        PoolStatus(
          state: state,
          size: puddle.pool_size,
          available: available,
          busy: busy_count,
          waiting: waiting_count,
        ),
      )
      actor.continue(puddle)
    }

    CheckIn(worker_pid) -> {
      case dict.get(puddle.busy_by_worker, worker_pid) {
        Ok(BusyEntry(user_pid, user_monitor, worker_monitor, subject)) -> {
          process.demonitor_process(user_monitor)
          let puddle = remove_busy_entry(puddle, worker_pid, user_pid)
          let puddle =
            serve_or_idle(puddle, worker_pid, worker_monitor, subject)
          actor.continue(puddle)
        }
        Error(Nil) -> actor.continue(puddle)
      }
    }

    DiscardWorker(worker_pid) -> {
      case dict.get(puddle.busy_by_worker, worker_pid) {
        Ok(BusyEntry(user_pid, user_monitor, worker_monitor, subject)) -> {
          process.demonitor_process(user_monitor)
          process.demonitor_process(worker_monitor)
          process.send(subject, ResourceShutdown(puddle.on_shutdown))
          let puddle = remove_busy_entry(puddle, worker_pid, user_pid)
          replace_crashed_worker(puddle)
        }
        Error(Nil) -> actor.continue(puddle)
      }
    }

    CheckOut(user_pid, client) -> {
      case puddle.idle_order {
        [] ->
          case
            has_lazy_capacity(puddle)
          {
            True -> try_lazy_create_and_checkout(puddle, user_pid, client)
            False -> {
              actor.send(client, Error(NoResourcesAvailable))
              actor.continue(puddle)
            }
          }

        [worker_pid, ..] ->
          checkout_idle_worker(puddle, worker_pid, user_pid, client)
      }
    }

    CheckOutBlocking(user_pid, client) -> {
      case puddle.idle_order {
        [] ->
          case
            has_lazy_capacity(puddle)
          {
            True -> try_lazy_create_and_checkout(puddle, user_pid, client)
            False -> {
              let user_monitor = process.monitor(user_pid)
              let selector =
                process.select_specific_monitor(
                  puddle.selector,
                  user_monitor,
                  ProcessDown,
                )
              let puddle =
                Puddle(
                  ..puddle,
                  selector: selector,
                  waiting: list.append(puddle.waiting, [
                    WaitingEntry(user_pid, user_monitor, client),
                  ]),
                )
              actor.continue(puddle)
              |> actor.with_selector(selector)
            }
          }

        [worker_pid, ..] ->
          checkout_idle_worker(puddle, worker_pid, user_pid, client)
      }
    }

    ProcessDown(process.ProcessDown(_, down_pid, _)) -> {
      case dict.get(puddle.idle, down_pid) {
        Ok(_) -> {
          let puddle = remove_from_idle(puddle, down_pid)
          replace_crashed_worker(puddle)
        }

        Error(Nil) ->
          case dict.get(puddle.busy_by_worker, down_pid) {
            Ok(BusyEntry(user_pid, user_monitor, _worker_monitor, _subject)) -> {
              process.demonitor_process(user_monitor)
              let puddle = remove_busy_entry(puddle, down_pid, user_pid)
              replace_crashed_worker(puddle)
            }

            Error(Nil) ->
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
                  let puddle =
                    serve_or_idle(puddle, worker_pid, worker_monitor, subject)
                  actor.continue(puddle)
                }

                Error(Nil) -> {
                  let puddle = remove_waiting_by_pid(puddle, down_pid)
                  actor.continue(puddle)
                }
              }
          }
      }
    }

    ProcessDown(process.PortDown(_, _, _)) -> actor.continue(puddle)
  }
}

// --- Resource message handler ---

fn handle_resource_message(
  resource: resource_type,
  msg: ResourceMessage(resource_type, result_type),
) {
  case msg {
    ResourceUsage(fun, client) -> {
      let next = fun(resource)
      actor.send(client, Ok(next))
      actor.continue(resource)
    }

    ResourceShutdown(shutdown_fn) -> {
      shutdown_fn(resource)
      actor.stop()
    }
  }
}
