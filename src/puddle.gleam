import gleam/io
import gleam/list
import gleam/queue
import gleam/result
import gleam/otp/task
import gleam/otp/port
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
      list.repeat("", size)
      |> list.map(fn(_) { new_resource() })
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
      process.sleep(2500)
      let puddle = put_back(puddle, resource)
      Ok(#(result, puddle))
    }
    Error(Nil) -> Error(Nil)
  }
}

pub type Command {
  Command(String)
}

pub type Data {
  Data(String)
}

pub fn main() {
  let puddle = new(128, fn() { start_port("cat") })
  inner(puddle, [], 32)
  |> list.map(fn(t) { task.await(t, 6000) })
  |> io.debug
}

pub fn inner(
  puddle,
  tasks: List(
    task.Task(
      List(Result(Result(Nil, Nil), process.CallError(Result(Nil, Nil)))),
    ),
  ),
  counter: Int,
) -> List(
  task.Task(List(Result(Result(Nil, Nil), process.CallError(Result(Nil, Nil))))),
) {
  case counter {
    0 -> tasks
    _ ->
      inner(
        puddle,
        list.append(
          tasks,
          [
            task.async(fn() {
              list.repeat(
                process.try_call(
                  puddle,
                  fn(self) {
                    Utilize(
                      fn(port) { send_to_port(port, Command("hello")) },
                      self,
                    )
                  },
                  5000,
                ),
                8,
              )
            }),
          ],
        ),
        counter - 1,
      )
  }
}

external fn start_port(String) -> port.Port =
  "puddle_ffi" "start_port"

external fn send_to_port(port.Port, Command) -> Nil =
  "puddle_ffi" "send_to_port"
