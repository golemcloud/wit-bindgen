//@ wasmtime-flags = '-Wcomponent-model-async'
//@ runtime-failure = ['nested-failure-stage-3', 'relay-resource-drop-1', 'async_2dcore14next__callback', 'wasm trap']

include!(env!("BINDINGS"));

use crate::test::moonbit_stream_producer_failure::operations::relay_failure;

struct Component;

export!(Component);

impl Guest for Component {
    async fn run() {
        let mut stream = relay_failure().await;
        let _ = stream.read(Vec::with_capacity(1)).await;
    }
}
