
///|
extern "wasm" fn load_bytes(ptr : Int) -> Int =
  #|(func (param i32) (result i32) local.get 0 i32.load8_u)

///|
extern "wasm" fn copy_bytes_from_memory(
  bytes : FixedArray[Byte],
  ptr : Int,
  len : Int,
) -> Unit =
  #|(func (param (ref $moonbit.bytes) i32 i32) (local i32)
  #|  (loop $copy
  #|    local.get 3 local.get 2 i32.lt_u
  #|    (if (then
  #|      local.get 0 local.get 3
  #|      local.get 1 local.get 3 i32.add i32.load8_u
  #|      array.set $moonbit.bytes
  #|      local.get 3 i32.const 1 i32.add local.set 3
  #|      br $copy))))

///|
extern "wasm" fn copy_bytes_to_memory(
  bytes : FixedArray[Byte],
  ptr : Int,
  len : Int,
) -> Unit =
  #|(func (param (ref $moonbit.bytes) i32 i32) (local i32)
  #|  (loop $copy
  #|    local.get 3 local.get 2 i32.lt_u
  #|    (if (then
  #|      local.get 1 local.get 3 i32.add
  #|      local.get 0 local.get 3 array.get_u $moonbit.bytes
  #|      i32.store8
  #|      local.get 3 i32.const 1 i32.add local.set 3
  #|      br $copy))))

///|
pub fn bytes2ptr(value : FixedArray[Byte]) -> Int {
  let len = byte_size(value.length(), 1)
  let ptr = malloc(len)
  copy_bytes_to_memory(value, ptr, len)
  ptr
}

///|
pub fn ptr2bytes(ptr : Int, len : Int) -> FixedArray[Byte] {
  ignore(byte_size(len, 1))
  let bytes : FixedArray[Byte] = FixedArray::make(len, 0)
  copy_bytes_from_memory(bytes, ptr, len)
  bytes
}
