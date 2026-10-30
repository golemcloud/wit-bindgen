//@ wasmtime-flags = '-Wcomponent-model-async'
//@ runtime-failure = ['nested-first-read-complete-11', 'nested-failure-stage-1', 'nested-failure-stage-2', 'nested-failure-stage-4', 'async_2dcore14next__callback', 'wasm trap']

include!(env!("BINDINGS"));

use crate::test::moonbit_stream_producer_failure::operations::nested_failure;
use wit_bindgen::StreamResult;

struct Component;

export!(Component);

impl Guest for Component {
    async fn run() {
        let mut stream = nested_failure().await;
        let (result, values) = stream.read(Vec::with_capacity(1)).await;
        assert_eq!(result, StreamResult::Complete(1));
        assert_eq!(values, [11]);
        eprintln!("nested-first-read-complete-11");
        let _ = stream.read(Vec::with_capacity(1)).await;
    }
}
