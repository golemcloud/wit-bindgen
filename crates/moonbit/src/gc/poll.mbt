///|
fn WaitableSet::poll(self : Self) -> (Events, Int32) {
  let ptr = @witCabi.int_array2ptr([0, 0])
  defer @witCabi.free(ptr)
  let event = waitable_set_poll(self.0, ptr)
  let payload = @witCabi.ptr2int_array(ptr, 2)
  (Events::new(EventCode::from(event), payload[0], payload[1]), payload[0])
}
