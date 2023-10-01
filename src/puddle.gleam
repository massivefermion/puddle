import gleam/list
import gleam/otp/actor
import gleam/erlang/process

pub opaque type Puddle(resource_type, result_type) {
  Puddle(
    idle: List(#(Int, process.Subject(Message(resource_type, result_type)))),
    busy: List(#(Int, process.Subject(Message(resource_type, result_type)))),
  )
}

pub type Message(resource_type, result_type) {
  Shutdown
  Utilize(
    fn(resource_type) -> result_type,
    reply_with: process.Subject(result_type),
  )
}

pub fn new(size: Int, new_resource: fn() -> Result(resource_type, Nil)) {
  case
    list.repeat("", size)
    |> list.index_map(fn(index, _) { index })
    |> list.try_map(fn(index) {
      case new_resource() {
        Ok(initial_state) -> {
          let assert Ok(subject) =
            actor.start(
              initial_state,
              fn(
                msg: Message(resource_type, result_type),
                resource: resource_type,
              ) {
                case msg {
                  Shutdown -> actor.Stop(process.Normal)
                  Utilize(func, client) -> {
                    let result = func(resource)
                    actor.send(client, result)
                    actor.continue(resource)
                  }
                }
              },
            )
          #(index, subject)
          |> Ok
        }
        Error(Nil) -> Error(Nil)
      }
    })
  {
    Ok(idle) ->
      Puddle(idle, [])
      |> Ok
    Error(Nil) -> Error(Nil)
  }
}

pub fn checkout(puddle) {
  case puddle {
    Puddle(idle, busy) ->
      case idle {
        [#(id, subject), ..rest] ->
          Ok(#(#(id, subject), Puddle(rest, list.prepend(busy, #(id, subject)))))
        [] -> Error(Nil)
      }
  }
}

pub fn put_back(puddle, subject_id) {
  case puddle {
    Puddle(idle, busy) -> {
      let assert Ok(#(subject, busy)) = list.key_pop(busy, subject_id)
      Puddle(list.key_set(idle, subject_id, subject), busy)
    }
  }
}
