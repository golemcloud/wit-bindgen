include!(env!("BINDINGS"));

use crate::exports::test::moonbit_stream_producer_failure::observer::{Guest, GuestLeaf};
use std::sync::atomic::{AtomicU32, Ordering};

struct Component;

export!(Component);

static LEAF_DROP_COUNT: AtomicU32 = AtomicU32::new(0);

struct MyLeaf;

impl Guest for Component {
    type Leaf = MyLeaf;

    fn mark(stage: u8) {
        eprintln!("nested-failure-stage-{stage}");
    }
}

impl GuestLeaf for MyLeaf {
    fn new() -> Self {
        MyLeaf
    }
}

impl Drop for MyLeaf {
    fn drop(&mut self) {
        let count = LEAF_DROP_COUNT.fetch_add(1, Ordering::SeqCst) + 1;
        assert_eq!(count, 1, "relay resource dropped more than once");
        eprintln!("relay-resource-drop-{count}");
    }
}
