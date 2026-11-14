// Copyright 2025 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// Host operations on an opaque execution context of the current
/// component-model task. `exchange(None)` returns a new handle to the current
/// context without changing it. `exchange(Some(handle))` consumes the handle,
/// installs its context and returns a new handle to the previous context.
/// `drop` releases a handle that was not installed.
priv struct TaskContextHooks {
  exchange : (Int?) -> Int
  drop : (Int) -> Unit
}

///|
let task_context_hooks : Ref[TaskContextHooks?] = Ref(None)

///|
/// Set while the runtime spawns a coroutine that produces data for a stream or
/// future, so that the coroutine joins its scope frame as a producer.
let spawning_producer : Ref[Bool] = Ref(false)

///|
/// The context a coroutine owns. Between turns, `saved` holds the coroutine's
/// own context. During a turn, `caller` holds the context that was installed
/// before the turn and is installed again when the turn ends.
priv struct TaskContext {
  mut saved : Int?
  mut caller : Int?
  frames : Array[TaskContextFrame]
  inherited : TaskContextFrame?
  producer : Bool
}

///|
/// A scope a coroutine entered after `push_task_context_frame`. Coroutines
/// spawned while it is the innermost scope of their spawner, and coroutines
/// they spawn in turn, inherit the spawner's context and are counted here
/// until they terminate.
pub struct TaskContextFrame {
  priv owner : Coroutine
  priv mut children : Int
  priv producers : @set.Set[Coroutine]
  priv settled : CondVar
}

///|
/// Install the hooks that switch the task context. Coroutines that never push
/// a frame, and do not inherit one, never call them.
#doc(hidden)
pub fn install_task_context_hooks(
  exchange~ : (Int?) -> Int,
  drop~ : (Int) -> Unit,
) -> Unit {
  task_context_hooks.val = Some({ exchange, drop, })
}

///|
fn task_context_hooks_or_abort() -> TaskContextHooks {
  match task_context_hooks.val {
    Some(hooks) => hooks
    None => abort("task context hooks are not installed")
  }
}

///|
/// Push a scope frame for the current coroutine. The current context becomes
/// owned by the coroutine: it is installed at the start of each of its turns,
/// and the caller's context is installed again at the end of each turn.
///
/// `capture_caller` must be `true` when the coroutine can suspend while the
/// frame is open. A synchronous scope passes `false` and makes no host call.
#doc(hidden)
pub fn push_task_context_frame(capture_caller~ : Bool) -> TaskContextFrame {
  let coro = current_coroutine()
  let hooks = task_context_hooks_or_abort()
  let frame = {
    owner: coro,
    children: 0,
    producers: @set.Set::new(),
    settled: CondVar(),
  }
  match coro.context {
    Some(ctx) => {
      guard !capture_caller || ctx.caller is Some(_) else {
        abort("an asynchronous scope cannot start inside a synchronous scope")
      }
      ctx.frames.push(frame)
    }
    None =>
      coro.context = Some({
        saved: None,
        caller: if capture_caller {
          Some((hooks.exchange)(None))
        } else {
          None
        },
        frames: [frame],
        inherited: None,
        producer: false,
      })
  }
  frame
}

///|
/// Abort unless every coroutine that inherited this frame has terminated.
#doc(hidden)
pub fn TaskContextFrame::check_joined(self : TaskContextFrame) -> Unit {
  if self.children > 0 {
    abort(
      "a scope exited while \{self.children} task(s) spawned in it are still running; join them before the scope exits",
    )
  }
  if !self.producers.is_empty() {
    abort(
      "a synchronous scope exited while a stream or future producer started in it is still running",
    )
  }
}

///|
/// Wait until every stream and future producer that inherited this frame has
/// terminated, cancelling them first when `cancel_producers` is set, then
/// abort if a spawned task is still running.
#doc(hidden)
pub async fn TaskContextFrame::settle(
  self : TaskContextFrame,
  cancel_producers? : Bool = false,
) -> Unit noraise {
  if cancel_producers {
    self.producers.each(Coroutine::cancel)
  }
  while !self.producers.is_empty() {
    self.settled.wait()
  }
  self.check_joined()
}

///|
/// Pop the innermost frame of the current coroutine. The frame must have been
/// pushed by this coroutine and every coroutine that inherited it must have
/// terminated.
#doc(hidden)
pub fn pop_task_context_frame(frame : TaskContextFrame) -> Unit {
  let coro = current_coroutine()
  guard physical_equal(frame.owner, coro) &&
    coro.context is Some(ctx) &&
    ctx.frames.last() is Some(top) &&
    physical_equal(top, frame) else {
    abort("scope frames must be popped in order by the task that pushed them")
  }
  frame.check_joined()
  ignore(ctx.frames.pop())
  if ctx.frames.is_empty() && ctx.inherited is None && ctx.caller is None {
    coro.context = None
  }
}

///|
fn Coroutine::current_frame(self : Coroutine) -> TaskContextFrame? {
  match self.context {
    Some(ctx) =>
      match ctx.frames.last() {
        Some(frame) => Some(frame)
        None => ctx.inherited
      }
    None => None
  }
}

///|
/// Called when `coro` is created. A coroutine spawned inside a scope inherits
/// the context its spawner has at that moment.
fn Coroutine::inherit_context(self : Coroutine) -> Unit {
  let producer = spawning_producer.val
  spawning_producer.val = false
  guard scheduler.curr_coro is Some(spawner) &&
    spawner.current_frame() is Some(frame) else {
    return
  }
  let hooks = task_context_hooks_or_abort()
  self.context = Some({
    saved: Some((hooks.exchange)(None)),
    caller: None,
    frames: [],
    inherited: Some(frame),
    producer,
  })
  if producer {
    frame.producers.add(self)
  } else {
    frame.children += 1
  }
}

///|
/// Called when `coro`'s body has terminated, still inside its last turn.
fn Coroutine::release_inherited_frame(self : Coroutine) -> Unit {
  guard self.context is Some({ inherited: Some(frame), producer, .. }) else {
    return
  }
  if producer {
    frame.producers.remove(self)
    if frame.producers.is_empty() {
      frame.settled.broadcast()
    }
  } else {
    frame.children -= 1
  }
}

///|
fn Coroutine::enter_context(self : Coroutine) -> Unit {
  guard self.context is Some(ctx) && ctx.saved is Some(saved) else { return }
  ctx.saved = None
  ctx.caller = Some((task_context_hooks_or_abort().exchange)(Some(saved)))
}

///|
fn Coroutine::leave_context(self : Coroutine) -> Unit {
  guard self.context is Some(ctx) else { return }
  let hooks = task_context_hooks_or_abort()
  let released = self.state is (Done | Fail(_) | Cancelled) ||
    (ctx.frames.is_empty() && ctx.inherited is None)
  if ctx.caller is Some(caller) {
    ctx.caller = None
    let outgoing = (hooks.exchange)(Some(caller))
    if released {
      (hooks.drop)(outgoing)
    } else {
      ctx.saved = Some(outgoing)
    }
  }
  if released {
    if ctx.saved is Some(saved) {
      ctx.saved = None
      (hooks.drop)(saved)
    }
    self.context = None
  }
}

///|
fn[T] spawn_producer(spawn : () -> T) -> T {
  spawning_producer.val = true
  defer {
    spawning_producer.val = false
  }
  spawn()
}
