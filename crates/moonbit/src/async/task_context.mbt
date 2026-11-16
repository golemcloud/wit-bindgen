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
  mut inherited : TaskContextFrame?
  producer : Bool
}

///|
/// A scope a coroutine entered after `push_task_context_frame`. Coroutines
/// spawned while it is the innermost scope of their spawner, and coroutines
/// they spawn in turn, inherit the spawner's context and are members of the
/// frame until they terminate.
///
/// A released frame whose members still run stays open: it closes, and its
/// parent frame counts it as pending, until the last member terminates.
pub struct TaskContextFrame {
  priv owner : Coroutine
  priv parent : TaskContextFrame?
  priv children : @set.Set[Coroutine]
  priv producers : @set.Set[Coroutine]
  priv settled : CondVar
  priv mut cancelling : Bool
  priv mut pending : Int
  priv mut close : (() -> Unit)?
  priv mut before : Int?
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
/// frame is open. The frame then also keeps the context installed before the
/// scope and installs it again in `release`. A synchronous scope passes
/// `false` and makes no host call.
#doc(hidden)
pub fn push_task_context_frame(capture_caller~ : Bool) -> TaskContextFrame {
  let coro = current_coroutine()
  let hooks = task_context_hooks_or_abort()
  let parent = coro.current_frame()
  match coro.context {
    Some(ctx) =>
      if capture_caller && ctx.caller is None {
        abort("an asynchronous scope cannot start inside a synchronous scope")
      }
    None =>
      coro.context = Some({
        saved: None,
        caller: if capture_caller {
          Some((hooks.exchange)(None))
        } else {
          None
        },
        frames: [],
        inherited: None,
        producer: false,
      })
  }
  let frame = {
    owner: coro,
    parent,
    children: Set([]),
    producers: Set([]),
    settled: CondVar(),
    cancelling: false,
    pending: 0,
    close: None,
    before: if capture_caller {
      Some((hooks.exchange)(None))
    } else {
      None
    },
  }
  guard coro.context is Some(ctx) else { panic() }
  ctx.frames.push(frame)
  frame
}

///|
/// The number of tasks that inherited this frame and still run, not counting
/// stream and future producers.
#doc(hidden)
pub fn TaskContextFrame::running_tasks(self : TaskContextFrame) -> Int {
  self.children.length()
}

///|
/// The number of stream and future producers that inherited this frame and
/// still run.
#doc(hidden)
pub fn TaskContextFrame::running_producers(self : TaskContextFrame) -> Int {
  self.producers.length()
}

///|
/// Wait until every stream and future producer that inherited this frame has
/// terminated and every released nested frame has closed.
#doc(hidden)
pub async fn TaskContextFrame::settle_producers(
  self : TaskContextFrame,
) -> Unit noraise {
  while !self.producers.is_empty() || self.pending > 0 {
    self.settled.wait()
  }
}

///|
/// End the scope without suspending. Every member still running is
/// cancelled, and tasks that inherit the frame later start cancelled. `close`
/// runs now when no member runs, and otherwise when the last member
/// terminates; until then the parent frame counts this frame as pending. An
/// asynchronous frame installs the context from before the scope again.
#doc(hidden)
pub fn TaskContextFrame::release(
  self : TaskContextFrame,
  close~ : () -> Unit,
) -> Unit {
  guard self.close is None && !self.cancelling else {
    abort("a scope frame was released twice")
  }
  self.cancelling = true
  self.children.each(Coroutine::cancel)
  self.producers.each(Coroutine::cancel)
  if self.drained() {
    close()
  } else {
    self.close = Some(close)
    if self.parent is Some(parent) {
      parent.pending += 1
    }
  }
  if self.before is Some(before) {
    self.before = None
    let hooks = task_context_hooks_or_abort()
    (hooks.drop)((hooks.exchange)(Some(before)))
  }
}

///|
/// Move every member of a synchronous frame to the parent frame and cancel
/// it. The members have not run yet, because a synchronous scope cannot
/// suspend; they get the current context, which must no longer contain the
/// scope.
#doc(hidden)
pub fn TaskContextFrame::detach_members(self : TaskContextFrame) -> Unit {
  if self.children.is_empty() && self.producers.is_empty() {
    return
  }
  let hooks = task_context_hooks_or_abort()
  let members = []
  self.children.each(task => members.push(task))
  self.producers.each(task => members.push(task))
  self.children.clear()
  self.producers.clear()
  for task in members {
    guard task.context is Some(ctx) else { continue }
    if ctx.saved is Some(saved) {
      (hooks.drop)(saved)
      ctx.saved = Some((hooks.exchange)(None))
    }
    ctx.inherited = self.parent
    if self.parent is Some(parent) {
      if ctx.producer {
        parent.producers.add(task)
      } else {
        parent.children.add(task)
      }
    }
    task.cancel()
  }
}

///|
/// Pop the innermost frame of the current coroutine. The frame must have been
/// pushed by this coroutine.
#doc(hidden)
pub fn pop_task_context_frame(frame : TaskContextFrame) -> Unit {
  let coro = current_coroutine()
  guard physical_equal(frame.owner, coro) &&
    coro.context is Some(ctx) &&
    ctx.frames.last() is Some(top) &&
    physical_equal(top, frame) else {
    abort("scope frames must be popped in order by the task that pushed them")
  }
  if frame.before is Some(before) {
    frame.before = None
    (task_context_hooks_or_abort().drop)(before)
  }
  ignore(ctx.frames.pop())
  if ctx.frames.is_empty() && ctx.inherited is None && ctx.caller is None {
    coro.context = None
  }
}

///|
fn TaskContextFrame::drained(self : TaskContextFrame) -> Bool {
  self.children.is_empty() && self.producers.is_empty() && self.pending == 0
}

///|
fn TaskContextFrame::close_if_drained(self : TaskContextFrame) -> Unit {
  guard self.close is Some(close) && self.drained() else { return }
  self.close = None
  close()
  if self.parent is Some(parent) {
    parent.pending -= 1
    if parent.pending == 0 {
      parent.settled.broadcast()
    }
    parent.close_if_drained()
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
/// the context its spawner has at that moment, and starts cancelled when the
/// scope has been released.
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
    frame.children.add(self)
  }
  if frame.cancelling {
    self.cancel()
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
    frame.children.remove(self)
  }
  frame.close_if_drained()
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
