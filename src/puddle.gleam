import gleam/list
import gleam/result
import gleam/otp/actor
import gleam/erlang/process

pub opaque type ManagerMessage(resource_type, result_type) {
  ManagerShutdown(fn(resource_type) -> Nil)
  CheckIn(process.Subject(ResourceMessage(resource_type, result_type)))
  CheckOut(
    process.Subject(
      Result(process.Subject(ResourceMessage(resource_type, result_type)), Nil),
    ),
  )
}

pub opaque type ResourceMessage(resource_type, result_type) {
  ResourceUsage(
    fn(resource_type) -> result_type,
    process.Subject(Result(result_type, Nil)),
  )
  ResourceShutdown(fn(resource_type) -> Nil)
}

type Puddle(resource_type, result_type) =
  List(process.Subject(ResourceMessage(resource_type, result_type)))

pub fn start(
  size: Int,
  resource_creation_function: fn() -> Result(resource_type, Nil),
) -> Result(
  process.Subject(ManagerMessage(resource_type, result_type)),
  actor.StartError,
) {
  use puddle <- result.then(
    new(size, resource_creation_function)
    |> result.map_error(fn(_) {
      actor.InitFailed(process.Abnormal("Failed to create new resource"))
    }),
  )
  actor.start(puddle, handle_manager_message)
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
  utilize(subject, fun, mine)
  let selector =
    process.new_selector()
    |> process.selecting(mine, fn(r) { r })
  let result =
    process.select(selector, timeout)
    |> result.flatten
  check_in(manager, subject)
  rest(result)
}

pub fn shutdown(manager, resource_shutdown_function) {
  process.send(manager, ManagerShutdown(resource_shutdown_function))
}

fn check_out(
  manager: process.Subject(ManagerMessage(resource_type, result_type)),
  timeout: Int,
) {
  process.try_call(manager, CheckOut, timeout)
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
  subject: process.Subject(ResourceMessage(resource_type, result_type)),
) {
  process.send(manager, CheckIn(subject))
}

fn new(
  size: Int,
  resource_creation_function: fn() -> Result(resource_type, Nil),
) -> Result(Puddle(resource_type, result_type), Nil) {
  list.repeat("", size)
  |> list.try_map(fn(_) {
    case resource_creation_function() {
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
    ManagerShutdown(resource_shutdown_function) -> {
      list.each(
        puddle,
        fn(item) {
          process.send(item, ResourceShutdown(resource_shutdown_function))
        },
      )
      actor.Stop(process.Normal)
    }
    CheckIn(subject) -> {
      actor.continue(list.prepend(puddle, subject))
    }
    CheckOut(client) -> {
      case puddle {
        [] -> {
          actor.send(client, Error(Nil))
          actor.continue(puddle)
        }
        [chosen, ..new_puddle] -> {
          actor.send(client, Ok(chosen))
          actor.continue(new_puddle)
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
