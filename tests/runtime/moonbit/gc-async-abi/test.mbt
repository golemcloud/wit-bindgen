//@ args = '--wasm-gc'
//@ [lang]
//@ path = 'gen/interface/test/gc-async-abi/consumer/stub.mbt'

///|
extern "wasm" fn memory_pages() -> Int32 =
  #|(func (result i32) memory.size)

///|
pub fn pages() -> UInt32 {
  memory_pages().reinterpret_as_uint()
}

///|
pub async fn consume(
  value : @async-core.Stream[Byte],
  stop_early : Bool,
  _background_group : @async-core.TaskGroup[Unit],
) -> UInt32 {
  let chunks : Array[FixedArray[Byte]] = []
  while value.read(1024) is Some(chunk) {
    chunks.push(chunk)
    if stop_early {
      break
    }
  }
  value.drop()
  // Retain every chunk until subsequent reads have reused their ABI storage.
  let mut offset = 0
  for chunk in chunks {
    for byte in chunk {
      guard byte == ((offset * 17 + 3) % 251).to_byte() else { panic() }
      offset = offset + 1
    }
  }
  offset.reinterpret_as_uint()
}
