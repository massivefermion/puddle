import gleam/list
import gleam/result
import gleam/otp/actor
import gleam/erlang/process

pub opaque type BookkeepingMessage(resource_type, result_type) {
  Shutdown
  CheckIn(process.Subject(UsageMessage(resource_type, result_type)))
  CheckOut(
    process.Subject(
      Result(process.Subject(UsageMessage(resource_type, result_type)), Nil),
    ),
  )
}

pub opaque type UsageMessage(resource_type, result_type) {
  UsageMessage(
    fn(resource_type) -> result_type,
    process.Subject(Result(result_type, Nil)),
  )
}

type Puddle(resource_type, result_type) =
  List(
    #(process.Pid, process.Subject(UsageMessage(resource_type, result_type))),
  )

pub fn start(
  size: Int,
  new_resource: fn() -> Result(resource_type, Nil),
) -> Result(
  process.Subject(BookkeepingMessage(resource_type, result_type)),
  actor.StartError,
) {
  use puddle <- result.then(
    new(size, new_resource)
    |> result.map_error(fn(_) {
      actor.InitFailed(process.Abnormal("Failed to create new resource"))
    }),
  )
  actor.start(puddle, handle_bookkeeping_message)
}

/// checks-out a resources, applies the function and then checks-in the resource
///
/// ## Example
///
/// ```gleam
/// >  let assert Ok(manager) =
/// >    puddle.start(
/// >      4,
/// >      fn() {
/// >        Ok(int.random(1024, 8192))
/// >      },
/// >    )
/// >
/// >  let t1 =
/// >    task.async(fn() {
/// >      use r <- puddle.apply(manager, fun, 32)
/// >      r
/// >   })
///
/// >  let t2 = 
/// >    task.async(fn() {
/// >      use r <- puddle.apply(manager, fun, 32)
/// >      r
/// >    })
/// 
/// >  task.await(t1, 32)
/// >  task.await(t2, 32)
/// ```
pub fn apply(
  manager: process.Subject(BookkeepingMessage(resource_type, result_type)),
  fun: fn(resource_type) -> result_type,
  timeout: Int,
  rest,
) {
  use subject <- result.then(check_out(manager, timeout))
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

fn check_out(
  manager: process.Subject(BookkeepingMessage(resource_type, result_type)),
  timeout: Int,
) {
  process.call(manager, CheckOut, timeout)
}

fn utilize(
  subject: process.Subject(UsageMessage(resource_type, result_type)),
  fun: fn(resource_type) -> result_type,
  mine: process.Subject(Result(result_type, Nil)),
) {
  process.send(subject, UsageMessage(fun, mine))
}

fn check_in(
  manager: process.Subject(BookkeepingMessage(resource_type, result_type)),
  subject: process.Subject(UsageMessage(resource_type, result_type)),
) {
  process.send(manager, CheckIn(subject))
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
    CheckIn(subject) -> {
      let pid = process.subject_owner(subject)
      actor.continue(list.prepend(puddle, #(pid, subject)))
    }
    CheckOut(client) -> {
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
    UsageMessage(fun, client) -> {
      let result = fun(resource)
      actor.send(client, Ok(result))
      actor.continue(resource)
    }
  }
}
