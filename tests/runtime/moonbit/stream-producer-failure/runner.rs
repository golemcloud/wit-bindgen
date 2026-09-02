//@ wasmtime-flags = '-Wcomponent-model-async'
//@ runtime-failure = ['direct-first-read-complete-42', 'async_2dcore14next__callback', 'wasm trap']

include!(env!("BINDINGS"));

use crate::test::moonbit_stream_producer_failure::operations::fail_after_write;
use wit_bindgen::StreamResult;

struct Component;

export!(Component);

impl Guest for Component {
    async fn run() {
        let mut stream = fail_after_write().await;
        let (result, values) = stream.read(Vec::with_capacity(1)).await;
        assert_eq!(result, StreamResult::Complete(1));
        assert_eq!(values, [42]);
        eprintln!("direct-first-read-complete-42");
        let _ = stream.read(Vec::with_capacity(1)).await;
        // Returning would mean the producer failure became ordinary EOF. The
        // runtime-test configuration requires this invocation to trap.
    }
}
