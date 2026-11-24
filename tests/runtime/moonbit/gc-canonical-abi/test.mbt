//@ args = '--wasm-gc'
//@ [lang]
//@ path = 'gen/interface/test/gc-canonical-abi/values/stub.mbt'

///|
pub fn echo(value : Payload) -> Payload {
  value
}

///|
extern "wasm" fn memory_pages() -> Int =
  #|(func (result i32) memory.size)

///|
pub fn pages() -> UInt {
  memory_pages().reinterpret_as_uint()
}
