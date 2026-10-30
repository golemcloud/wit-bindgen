//@ [lang]
//@ path = 'gen/interface/test/outlined-return/values/stub.mbt'

///|
extern "wasm" fn memory_pages() -> Int =
  #|(func (result i32) memory.size)

///|
pub fn pages() -> UInt {
  memory_pages().reinterpret_as_uint()
}

///|
pub async fn get(_background_group : @async-core.TaskGroup[Unit]) -> Array[Row] {
  Array::makei(1024, fn(i) {
    { prefix: i.reinterpret_as_uint(), value: { text: "left λ", tags: ["right!", "tail"] } }
  })
}
