///|
#borrow(array)
extern "wasm" fn int_array2ptr(array : FixedArray[Int32]) -> Int32 =
  #|(func (param i32) (result i32) local.get 0)

///|
fn WaitableSet::poll(self : Self) -> (Events, Int32) {
  let payload : FixedArray[Int32] = FixedArray::make(2, 0)
  let event = waitable_set_poll(self.0, int_array2ptr(payload))
  (Events::new(EventCode::from(event), payload[0], payload[1]), payload[0])
}
