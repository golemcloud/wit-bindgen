//@ [lang]
//@ path = 'gen/interface/test/moonbit-stream-producer-failure/operations/stub.mbt'

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
