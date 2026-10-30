//@ [lang]
//@ path = 'gen/interface/test/moonbit-stream-producer-failure/operations/stub.mbt'
//@ pkg_config = """{ "warn-list": "-44", "supported-targets": "+wasm", "import": [{ "path": "test/moonbit-stream-producer-failure/async-core", "alias": "async-core" }, { "path": "test/moonbit-stream-producer-failure/interface/test/moonbit-stream-producer-failure/observer", "alias": "observer" }] }"""

///|
suberror ExpectedProducerFailure derive(Debug)

///|
pub async fn fail_after_write(
  _background_group : @async-core.TaskGroup[Unit],
) -> @async-core.Stream[Byte] {
  @async-core.Stream::produce(async fn(sink) {
    let data : FixedArray[Byte] = [42]
    guard sink.write_all(data[:]) else {
      abort("stream closed before accepting its value")
    }
    raise ExpectedProducerFailure
  })
}

///|
pub async fn nested_failure(
  background_group : @async-core.TaskGroup[Unit],
) -> @async-core.Stream[Byte] {
  let (defer_gate, _defer_promise) : (
    @async-core.Future[Unit],
    @async-core.Promise[Unit],
  ) = @async-core.Future::new()
  background_group.add_defer(async fn() {
    defer @observer.mark(4)
    defer_gate.get()
  })
  @async-core.Stream::produce(async fn(sink) {
    let first : FixedArray[Byte] = [11]
    guard sink.write_all(first[:]) else {
      abort("outer stream closed before accepting its first value")
    }
    let nested = @async-core.Stream::produce(async fn(nested_sink) {
      let data : FixedArray[Byte] = [22]
      guard nested_sink.write_all(data[:]) else {
        abort("nested stream closed before accepting its value")
      }
      raise ExpectedProducerFailure
    })
    defer @observer.mark(2)
    guard nested.read(1) is Some(data) && data.length() == 1 else {
      abort("nested stream did not deliver its accepted value")
    }
    @observer.mark(1)
    guard sink.write_all(data[:]) else {
      abort("outer stream closed while draining nested failure")
    }
  })
}

///|
pub async fn relay_failure(
  _background_group : @async-core.TaskGroup[Unit],
) -> @async-core.Stream[@observer.Leaf] {
  let retained : Ref[@observer.Leaf?] = Ref(Some(@observer.Leaf::leaf()))
  @async-core.Stream::from_source(
    async fn(_count) -> FixedArray[@observer.Leaf]? {
      raise ExpectedProducerFailure
    },
    async fn() -> Unit {
      @observer.mark(3)
      match retained.val {
        Some(value) => {
          retained.val = None
          value.drop()
        }
        None => abort("relay source rejected more than once")
      }
    },
    fn() -> Unit {
      match retained.val {
        Some(value) => {
          retained.val = None
          value.drop()
        }
        None => ()
      }
    },
  )
}
