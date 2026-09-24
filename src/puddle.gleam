import gleam/dict
import gleam/erlang/process
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result

///
/// Strategy for selecting which idle resource to check out.
///
/// - `FIFO` (default): Oldest idle resource first. Provides fair ordering.
/// - `LIFO`: Most recently returned resource first. Better cache locality.
///
pub type CheckoutStrategy {
  FIFO
  LIFO
}

///
/// Strategy for when resources are created in the pool.
///
/// - `Eager` (default): Create all resources at pool startup.
/// - `Lazy`: Create resources on first demand, up to the pool `size`.
///
pub type CreationStrategy {
  Lazy
  Eager
}

///
/// The result of a resource usage function, indicating whether to keep
/// or discard the resource after use.
///
/// - `Keep(value)`: Return the resource to the pool with the result value.
/// - `Discard(value)`: Destroy the resource and create a replacement, returning the value.
///
pub type Next(result_type) {
  Keep(result_type)
  Discard(result_type)
}

///
/// Current state of the resource pool.
///
/// - `Ready`: Idle resources are available for immediate checkout.
/// - `Full`: All resources are busy, no waiters queued.
/// - `Overloaded`: All resources are busy, requests are queued.
///
pub type PoolState {
  Ready
  Full
  Overloaded
}

///
/// Status snapshot of the resource pool.
///
/// Contains the current state, configured size, and counts of available,
/// busy, and waiting resources/requests.
///
pub type PoolStatus {
  PoolStatus(
    state: PoolState,
    size: Int,
    available: Int,
    busy: Int,
    waiting: Int,
  )
}

///
/// Errors that can occur when applying a function to a pooled resource.
///
/// - `NoResourcesAvailable`: Pool exhausted and no lazy capacity (non-blocking checkout).
/// - `CheckoutTimeout`: Timeout while waiting for a resource (blocking checkout).
/// - `PoolShuttingDown`: Pool is shutting down, no new checkouts allowed.
///
pub type ApplyError {
  NoResourcesAvailable
  CheckoutTimeout
  PoolShuttingDown
}

// --- Builder ---

///
/// Opaque builder type for configuring and creating a resource pool.
///
/// Use `puddle.new/1` to create a builder, then chain configuration functions
/// before calling `puddle.start/2` or `puddle.supervised/2`.
///
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

///
/// Create a new pool builder with a resource creation function.
///
/// The `create_resource` function is called to create new resources.
/// It should return `Ok(resource)` on success or `Error(Nil)` on failure.
///
/// Default configuration:
/// - Size: 10
/// - Checkout strategy: FIFO
/// - Creation strategy: Eager
/// - Shutdown callback: no-op
/// - Name: None
///
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

///
/// Set the maximum number of resources in the pool.
///
/// Default: 10
///
/// When using `Lazy` creation strategy, resources are created up to this limit
/// on demand. When using `Eager` strategy, this many resources are created at startup.
///
pub fn size(
  builder: Builder(resource_type, result_type),
  size: Int,
) -> Builder(resource_type, result_type) {
  Builder(..builder, size: size)
}

///
/// Set the checkout strategy for selecting idle resources.
///
/// Default: `FIFO`
///
/// - `FIFO`: Oldest idle resource first (fair ordering)
/// - `LIFO`: Most recently returned resource first (better cache locality)
///
pub fn checkout_strategy(
  builder: Builder(resource_type, result_type),
  strategy: CheckoutStrategy,
) -> Builder(resource_type, result_type) {
  Builder(..builder, checkout_strategy: strategy)
}

///
/// Set the resource creation strategy.
///
/// Default: `Eager`
///
/// - `Eager`: Create all resources at pool startup
/// - `Lazy`: Create resources on first demand, up to `size`
///
pub fn creation_strategy(
  builder: Builder(resource_type, result_type),
  strategy: CreationStrategy,
) -> Builder(resource_type, result_type) {
  Builder(..builder, creation_strategy: strategy)
}

///
/// Set a callback to run when each resource is shut down.
///
/// The callback is called for every resource in the pool when:
/// - The pool is shut down via `puddle.shutdown/1`
/// - A resource is discarded via `puddle.discard/1`
/// - A worker process crashes and is replaced
///
/// Use this to clean up resources (e.g., close database connections).
///
/// Default: no-op
///
pub fn on_shutdown(
  builder: Builder(resource_type, result_type),
  callback: fn(resource_type) -> Nil,
) -> Builder(resource_type, result_type) {
  Builder(..builder, on_shutdown: callback)
}

///
/// Register the pool under a globally accessible name.
///
/// The pool can then be accessed from anywhere using
/// `process.named_subject(name)` without passing the manager reference.
///
/// ```gleam
/// import gleam/erlang/process
///
/// let pool_name = process.new_name("my_db_pool")
/// let assert Ok(manager) =
///   puddle.new(create_connection)
///   |> puddle.size(10)
///   |> puddle.name(pool_name)
///   |> puddle.start(5000)
///
/// // Later, from anywhere:
/// let manager = process.named_subject(pool_name)
/// ```
///
pub fn name(
  builder: Builder(resource_type, result_type),
  pool_name: process.Name(ManagerMessage(resource_type, result_type)),
) -> Builder(resource_type, result_type) {
  Builder(..builder, name: Some(pool_name))
}

// --- Convenience constructors for Next ---

///
/// Signal to keep the resource in the pool after use.
///
/// Returns `Next(result_type)` wrapping the value to pass to the continuation.
///
pub fn keep(value: result_type) -> Next(result_type) {
  Keep(value)
}

///
/// Signal to discard the resource and create a replacement.
///
/// The resource will be shut down via the `on_shutdown` callback and a new
/// resource will be created (up to the pool size limit).
///
/// Returns `Next(result_type)` wrapping the value to pass to the continuation.
///
pub fn discard(value: result_type) -> Next(result_type) {
  Discard(value)
}

// --- Messages ---

///
/// Internal message type for the pool manager actor.
///
/// This type is opaque - use the public API functions instead of sending
/// these messages directly.
///
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

///
/// Internal message type for resource worker actors.
///
/// This type is opaque - use the public API functions instead.
///
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

///
/// Start the resource pool and return a manager subject.
///
/// The pool is started as a supervised actor. The `timeout` parameter
/// is the maximum time (in milliseconds) to wait for the pool to start
/// and for initial resource creation (if using `Eager` strategy).
///
/// Returns `Ok(manager_subject)` on success, or `Error(StartError)` if
/// the actor fails to start or resource creation fails.
///
/// ```gleam
/// let assert Ok(manager) =
///   puddle.new(create_connection)
///   |> puddle.size(10)
///   |> puddle.start(5000)
/// ```
///
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

///
/// Create a child specification for running the pool under an OTP supervisor.
///
/// The pool will be started as a worker under the supervisor. The `timeout`
/// parameter is the maximum time (in milliseconds) to wait for the pool
/// to start and for initial resource creation (if using `Eager` strategy).
///
/// Use with `gleam/otp/static_supervisor` or `gleam/otp/dynamic_supervisor`.
///
/// ```gleam
/// import gleam/otp/static_supervisor
///
/// let child_spec =
///   puddle.new(create_resource)
///   |> puddle.size(5)
///   |> puddle.supervised(5000)
///
/// let assert Ok(_supervisor) =
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(child_spec)
///   |> static_supervisor.start
/// ```
///
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

///
/// Apply a function to a pooled resource (non-blocking checkout).
///
/// Checks out a resource, applies `fun` to it, and returns the result.
/// If no resource is available and the pool has no lazy capacity,
/// returns `Error(NoResourcesAvailable)` immediately.
///
/// The `fun` function receives the resource and must return a `Next(result_type)`:
/// - `puddle.keep(value)` - return resource to pool, continue with `value`
/// - `puddle.discard(value)` - destroy resource, create replacement, continue with `value`
///
/// The `timeout` is the maximum time (in milliseconds) to wait for:
/// - Resource checkout (if pool not exhausted)
/// - Function execution and result
///
/// Uses the `rest` callback to handle the final result or error.
///
/// ```gleam
/// let result = {
///   use r <- puddle.apply(manager, fn(conn) {
///     case db.query(conn, "SELECT 1") {
///       Ok(rows) -> puddle.keep(rows)
///       Error(_) -> puddle.discard([])
///     }
///   }, 1000)
///   r
/// }
/// ```
///
pub fn apply(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  fun: fn(resource_type) -> Next(result_type),
  timeout: Int,
  rest,
) {
  use subject <- result.try(check_out(manager, timeout))
  use_and_return(manager, subject, fun, timeout, rest)
}

///
/// Apply a function to a pooled resource (blocking checkout).
///
/// Similar to `apply/4`, but if all resources are busy, the request
/// is queued until a resource becomes available or the timeout expires.
///
/// If a resource becomes available within `timeout` milliseconds, the
/// function is applied and the result returned. Otherwise, returns
/// `Error(CheckoutTimeout)`.
///
/// The `timeout` applies to the total time waiting for a resource
/// plus function execution.
///
/// ```gleam
/// let result = {
///   use r <- puddle.apply_blocking(manager, fn(n) { puddle.keep(n) }, 5000)
///   r
/// }
/// ```
///
pub fn apply_blocking(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  fun: fn(resource_type) -> Next(result_type),
  timeout: Int,
  rest,
) {
  use subject <- result.try(check_out_blocking(manager, timeout))
  use_and_return(manager, subject, fun, timeout, rest)
}

///
/// Gracefully shut down the resource pool.
///
/// Sends a shutdown signal to the pool manager. The manager will:
/// 1. Stop accepting new checkouts
/// 2. Wait for currently checked-out resources to be returned
/// 3. Call the `on_shutdown` callback for each resource
/// 4. Stop the manager actor
///
/// This function returns immediately; shutdown happens asynchronously.
/// Use `puddle.status/2` to monitor shutdown progress if needed.
///
/// ```gleam
/// puddle.shutdown(manager)
/// ```
///
pub fn shutdown(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
) {
  process.send(manager, ManagerShutdown)
}

///
/// Get the current status of the resource pool.
///
/// Returns a `PoolStatus` record containing:
/// - `state`: `Ready`, `Full`, or `Overloaded`
/// - `size`: configured pool size
/// - `available`: number of idle resources
/// - `busy`: number of checked-out resources
/// - `waiting`: number of queued blocking requests
///
/// The `timeout` is the maximum time (in milliseconds) to wait for
/// the status response from the manager.
///
/// ```gleam
/// let status = puddle.status(manager, 1000)
/// case status.state {
///   puddle.Ready -> io.debug("Pool ready")
///   puddle.Full -> io.debug("Pool full")
///   puddle.Overloaded -> io.debug("Pool overloaded")
/// }
/// ```
///
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
    process.select_specific_monitor(puddle.selector, user_monitor, ProcessDown)

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
          case has_lazy_capacity(puddle) {
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
          case has_lazy_capacity(puddle) {
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
