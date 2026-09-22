//@ wasmtime-flags = '-Wcomponent-model-async'
include!(env!("BINDINGS"));

struct Component;
export!(Component);

impl Guest for Component {
    async fn run() {
        for bytes in [false, true] {
            for partial in [false, true] {
                let mut stream = test::byte_stream_batching::producer::produce(bytes).await;
                let mut offset = 0;
                let mut calls = 0;
                loop {
                    let capacity = if partial && calls == 0 { 17 } else { 65536 };
                    let (result, values) = stream.read(Vec::with_capacity(capacity)).await;
                    if result == wit_bindgen::StreamResult::Dropped {
                        assert!(values.is_empty());
                        break;
                    }
                    assert_eq!(result, wit_bindgen::StreamResult::Complete(values.len()));
                    assert!(!values.is_empty());
                    for (i, value) in values.iter().enumerate() {
                        assert_eq!(*value, ((offset + i) % 251) as u8);
                    }
                    offset += values.len();
                    calls += 1;
                }
                assert_eq!(offset, 131073);
            }
        }
    }
}
