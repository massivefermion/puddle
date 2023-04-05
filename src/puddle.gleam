import gleam/list
import gleam/queue
import gleam/otp/actor
import gleam/erlang/process

pub opaque type Puddle(resource_type) {
  Puddle(queue.Queue(resource_type))
}

pub type Message(resource_type, result_type) {
  Shutdown
  Utilize(
    fn(resource_type) -> result_type,
    reply_with: process.Subject(Result(result_type, Nil)),
  )
}

pub fn new(
  size: Int,
  new_resource: fn() -> resource_type,
) -> process.Subject(Message(resource_type, result_type)) {
  let assert Ok(actor) =
    actor.start(
      list.repeat(new_resource(), size)
      |> queue.from_list
      |> Puddle,
      fn(
        msg: Message(resource_type, result_type),
        puddle: Puddle(resource_type),
      ) {
        case msg {
          Shutdown -> actor.Stop(process.Normal)
          Utilize(func, client) -> {
            case use_one_and_return(puddle, func) {
              Ok(#(result, puddle)) -> {
                process.send(client, Ok(result))
                actor.Continue(puddle)
              }
              Error(Nil) -> {
                process.send(client, Error(Nil))
                actor.Continue(puddle)
              }
            }
          }
        }
      },
    )

  actor
}

fn checkout(
  puddle: Puddle(resource_type),
) -> Result(#(resource_type, Puddle(resource_type)), Nil) {
  case puddle {
    Puddle(queue) ->
      case queue.pop_back(queue) {
        Ok(#(resource, queue)) -> Ok(#(resource, Puddle(queue)))
        Error(Nil) -> Error(Nil)
      }
  }
}

fn put_back(puddle: Puddle(resource_type), resource: resource_type) {
  case puddle {
    Puddle(queue) -> Puddle(queue.push_front(queue, resource))
  }
}

fn use_one_and_return(
  puddle: Puddle(resource_type),
  func: fn(resource_type) -> result_type,
) -> Result(#(result_type, Puddle(resource_type)), Nil) {
  case checkout(puddle) {
    Ok(#(resource, puddle)) -> {
      let result = func(resource)
      process.sleep(5000)
      let puddle = put_back(puddle, resource)
      Ok(#(result, puddle))
    }
    Error(Nil) -> Error(Nil)
  }
}
