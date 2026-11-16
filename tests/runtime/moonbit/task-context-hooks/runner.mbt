//@ wasmtime-flags = '-Wcomponent-model-async'
//@ [lang]
//@ path = 'gen/world/runner/stub.mbt'
//@ pkg_config = '''
//@ import {
//@   "test/moonbit-task-context-hooks/async-core" @async-core,
//@   "test/moonbit-task-context-hooks/interface/test/moonbit-task-context-hooks/operations" @operations,
//@ }
//@
//@ supported_targets = "wasm"
//@ '''

///|
pub async fn run(_background_group : @async-core.TaskGroup[Unit]) -> Unit {
  // Repeated exports start each from a fresh component task.
  for _ in 0..<2 {
    guard @operations.exercise() else { panic() }
  }
}
