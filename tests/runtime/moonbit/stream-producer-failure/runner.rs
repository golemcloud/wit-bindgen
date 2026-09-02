//@ wasmtime-flags = '-Wcomponent-model-async'
//@ runtime-failure = 'wasm trap'

include!(env!("BINDINGS"));

use crate::test::moonbit_stream_producer_failure::operations::fail_after_write;

struct Component;

export!(Component);

impl Guest for Component {
    async fn run() {
        let mut stream = fail_after_write().await;
        let _ = stream.read(Vec::with_capacity(1)).await;
        let _ = stream.read(Vec::with_capacity(1)).await;
        // Returning would mean the producer failure became ordinary EOF. The
        // runtime-test configuration requires this invocation to trap.
    }
}
