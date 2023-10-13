import gleam/list
import gleam/result
import gleam/otp/actor
import gleam/erlang/process

pub type UsageMessage(resource_type, result_type) {
  UsageMessage(
    fn(resource_type) -> result_type,
    process.Subject(Result(result_type, Nil)),
  )
}

pub type BookkeepingMessage(resource_type, result_type) {
  Shutdown
  PutBack(process.Subject(UsageMessage(resource_type, result_type)))
  Checkout(
    process.Subject(
      Result(process.Subject(UsageMessage(resource_type, result_type)), Nil),
    ),
  )
}

type Puddle(resource_type, result_type) =
  List(
    #(process.Pid, process.Subject(UsageMessage(resource_type, result_type))),
  )

pub fn start_manager(
  size: Int,
  new_resource: fn() -> Result(resource_type, Nil),
) -> Result(
  process.Subject(BookkeepingMessage(resource_type, result_type)),
  Nil,
) {
  use puddle <- result.then(new(size, new_resource))
  actor.start(puddle, handle_bookkeeping_message)
  |> result.nil_error()
}

fn new(
  size: Int,
  new_resource: fn() -> Result(resource_type, Nil),
) -> Result(Puddle(resource_type, result_type), Nil) {
  list.repeat("", size)
  |> list.try_map(fn(_) {
    case new_resource() {
      Ok(initial_state) -> {
        actor.start(initial_state, handle_usage_message)
        |> result.map(fn(subject) {
          let pid = process.subject_owner(subject)
          #(pid, subject)
        })
        |> result.nil_error()
      }
      Error(Nil) -> Error(Nil)
    }
  })
}

fn handle_bookkeeping_message(
  msg: BookkeepingMessage(resource_type, result_type),
  puddle: Puddle(resource_type, result_type),
) {
  case msg {
    Shutdown -> {
      list.each(puddle, fn(item) { process.kill(item.0) })
      actor.Stop(process.Normal)
    }
    PutBack(subject) -> {
      let pid = process.subject_owner(subject)
      actor.continue(list.prepend(puddle, #(pid, subject)))
    }
    Checkout(client) -> {
      case puddle {
        [] -> {
          actor.send(client, Error(Nil))
          actor.continue(puddle)
        }
        [#(_, chosen), ..new_puddle] -> {
          actor.send(client, Ok(chosen))
          actor.continue(new_puddle)
        }
      }
    }
  }
}

fn handle_usage_message(
  msg: UsageMessage(resource_type, result_type),
  resource: resource_type,
) {
  case msg {
    UsageMessage(func, client) -> {
      let result = func(resource)
      actor.send(client, Ok(result))
      actor.continue(resource)
    }
  }
}
