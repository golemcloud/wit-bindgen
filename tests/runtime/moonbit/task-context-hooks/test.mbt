//@ wasmtime-flags = '-Wcomponent-model-async'
//@ [lang]
//@ path = 'gen/interface/test/moonbit-task-context-hooks/operations/stub.mbt'

// A guest-side model of a host task context: the ambient context is a list of
// scope names, and handles are snapshots of it.

///|
let ambient : Ref[Array[String]] = Ref([])

///|
let handles : Map[Int, Array[String]] = Map([])

///|
let next_handle : Ref[Int] = Ref(1)

///|
let exchanges : Ref[Int] = Ref(0)

///|
let failures : Array[String] = []

///|
fn fake_exchange(next : Int?) -> Int {
  exchanges.val += 1
  let handle = next_handle.val
  next_handle.val += 1
  handles[handle] = ambient.val.copy()
  if next is Some(next) {
    guard handles.get(next) is Some(context) else {
      abort("installed an unknown or consumed handle")
    }
    handles.remove(next)
    ambient.val = context
  }
  handle
}

///|
fn fake_drop(handle : Int) -> Unit {
  guard handles.get(handle) is Some(_) else {
    abort("dropped an unknown or consumed handle")
  }
  handles.remove(handle)
}

///|
fn check(label : String, condition : Bool) -> Unit {
  if !condition {
    failures.push(label)
  }
}

///|
fn sees(label : String, expected : Array[String]) -> Unit {
  check(label, ambient.val == expected)
}

///|
suberror ExpectedFailure derive(Debug)

///|
#deprecated
pub extend ExpectedFailure with Debug::{to_repr}

///|
/// Mirrors a custom durable operation: the scope is installed on the task when
/// the body starts and removed when it ends, normally or not.
async fn scope(name : String, body : async () -> Unit) -> Unit {
  let frame = @async-core.push_task_context_frame(capture_caller=true)
  let entered = ambient.val.copy()
  entered.push(name)
  ambient.val = entered
  defer {
    ambient.val = ambient.val.filter(scope => scope != name)
    @async-core.pop_task_context_frame(frame)
  }
  body()
  frame.settle()
}

///|
fn gate() -> @async-core.Semaphore {
  @async-core.Semaphore(1, initial_value=0)
}

///|
/// Switches between two coroutines without any scope.
async fn idle_round() -> Unit {
  @async-core.with_task_group(async fn(group) {
    let go = gate()
    group.spawn_bg(async fn() { go.acquire() })
    go.release()
  })
}

///|
pub async fn exercise(background_group : @async-core.TaskGroup[Unit]) -> Bool {
  ignore(background_group)
  failures.clear()
  exchanges.val = 0
  @async-core.install_task_context_hooks(exchange=fake_exchange, drop=fake_drop)

  // Without frames, switching coroutines calls no hook.
  idle_round()
  check("no frames, no hook calls", exchanges.val == 0)

  // Siblings keep their own scope across suspensions; a root sibling that runs
  // while both wait sees no scope.
  let to_a = gate()
  let to_b = gate()
  let to_root = gate()
  @async-core.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      scope("a", async fn() {
        sees("a first turn", ["a"])
        to_b.release()
        to_a.acquire()
        sees("a second turn", ["a"])
        to_root.release()
        to_a.acquire()
        sees("a last turn", ["a"])
      })
    })
    group.spawn_bg(async fn() {
      scope("b", async fn() {
        to_b.acquire()
        sees("b first turn", ["b"])
        to_a.release()
        to_b.acquire()
        sees("b last turn", ["b"])
        to_a.release()
      })
    })
    group.spawn_bg(async fn() {
      to_root.acquire()
      sees("root sibling", [])
      to_b.release()
    })
  })
  sees("after siblings", [])

  // Nesting, and inheritance of the spawner's context at spawn time.
  let to_child = gate()
  let to_inner = gate()
  scope("outer", async fn() {
    @async-core.with_task_group(async fn(group) {
      group.spawn_bg(async fn() {
        to_child.acquire()
        sees("inherited", ["outer"])
        scope("child", async fn() {
          to_inner.release()
          to_child.acquire()
          sees("nested in inherited", ["outer", "child"])
        })
        sees("inherited after nested", ["outer"])
        to_inner.release()
      })
      scope("inner", async fn() {
        sees("inner first turn", ["outer", "inner"])
        to_child.release()
        to_inner.acquire()
        sees("inner last turn", ["outer", "inner"])
        to_child.release()
      })
      to_inner.acquire()
      sees("group body after inner", ["outer"])
    })
    sees("outer after group", ["outer"])
  })
  sees("after nesting", [])

  // Cancellation cleanup runs in the cancelled coroutine's scope.
  let cleanup_saw : Ref[Array[String]?] = Ref(None)
  let started = gate()
  let never = gate()
  let failed : Result[Unit, Error] = Ok(
    @async-core.with_task_group(async fn(group) {
      group.spawn_bg(async fn() {
        scope("cancelled", async fn() {
          defer {
            cleanup_saw.val = Some(ambient.val.copy())
          }
          started.release()
          never.acquire()
        })
      })
      started.acquire()
      sees("failing sibling", [])
      raise ExpectedFailure
    }),
  ) catch {
    error => Err(error)
  }
  check("group failed", failed is Err(ExpectedFailure))
  check("cancel cleanup scope", cleanup_saw.val == Some(["cancelled"]))
  sees("after cancellation", [])

  // A stream producer started in a scope inherits it, and the scope waits
  // for the producer to terminate.
  let produced_in : Ref[Array[String]?] = Ref(None)
  let producer_finished = Ref(false)
  let release_producer = gate()
  scope("streaming", async fn() {
    let stream : @async-core.Stream[Int] = @async-core.Stream::produce(async fn(
      sink,
    ) {
      produced_in.val = Some(ambient.val.copy())
      let values : FixedArray[Int] = [1, 2]
      guard sink.write_all(values[:]) else { return }
      sink.close()
      release_producer.acquire()
      sees("producer after close", ["streaming"])
      producer_finished.val = true
    })
    let mut received = 0
    while stream.read(8) is Some(chunk) {
      received += chunk.length()
    }
    check("stream values", received == 2)
    release_producer.release()
    check("producer outlives the body", !producer_finished.val)
  })
  check("producer scope", produced_in.val == Some(["streaming"]))
  check("scope waited for producer", producer_finished.val)
  sees("after streaming", [])

  // The first suspension after the last scope closed installs the caller's
  // context again and releases ownership.
  idle_round()
  let before = exchanges.val

  // A synchronous frame calls no hook.
  let after_restore = exchanges.val
  let frame = @async-core.push_task_context_frame(capture_caller=false)
  @async-core.pop_task_context_frame(frame)
  check("sync frame, no hook calls", exchanges.val == after_restore)

  // After every scope closed, coroutines own nothing again.
  idle_round()
  check("released ownership", exchanges.val == before)
  check("scopes used hooks", exchanges.val > 0)
  check("no leaked handles", handles.is_empty())
  failures.is_empty()
}
