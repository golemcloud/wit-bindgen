//@ [lang]
//@ path = 'gen/interface/test/byte-stream-batching/producer/stub.mbt'

///|
pub async fn produce(
  bytes : Bool,
  _background_group : @async-core.TaskGroup[Unit],
) -> @async-core.Stream[Byte] {
  @async-core.Stream::produce(async fn(sink) {
    let mut offset = 0
    let mut writes = 0
    if bytes {
      let data = Bytes::makei(131073, i => (i % 251).to_byte())
      while offset < data.length() {
        let written = sink.write_bytes(data[offset:])
        guard written == (if writes < 2 { 65536 } else { 1 }) else { panic() }
        offset = offset + written
        writes = writes + 1
      }
    } else {
      let data = FixedArray::makei(131073, i => (i % 251).to_byte())
      while offset < data.length() {
        let written = sink.write(data[offset:])
        guard written == (if writes < 2 { 65536 } else { 1 }) else { panic() }
        offset = offset + written
        writes = writes + 1
      }
    }
    guard writes == 3 else { panic() }
  })
}
