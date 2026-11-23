//@ wasmtime-flags = '-Wcomponent-model-async'

include!(env!("BINDINGS"));

use futures::task::noop_waker_ref;
use std::future::Future;
use std::task::Context;
use test::gc_async_abi::consumer::{consume, pages};

struct Component;
export!(Component);

impl Guest for Component {
    async fn run() {
        for _ in 0..8 {
            exercise().await;
        }
        let warm = pages();
        for _ in 0..128 {
            exercise().await;
        }
        assert_eq!(pages(), warm, "canonical stream buffers must be reused");
    }
}

async fn exercise() {
    for stop_early in [false, true] {
        let (mut writer, reader) = wit_stream::new::<u8>();
        let send = async move {
            let values = (0..8193).map(|i| ((i * 17 + 3) % 251) as u8).collect();
            let remaining = writer.write_all(values).await;
            assert_eq!(remaining.is_empty(), !stop_early);
        };
        let ((), count) = futures::join!(send, consume(reader, stop_early));
        assert_eq!(count, if stop_early { 1024 } else { 8193 });
    }

    let (mut writer, reader) = wit_stream::new::<u8>();
    let mut pending = Box::pin(consume(reader, false));
    assert!(
        pending
            .as_mut()
            .poll(&mut Context::from_waker(noop_waker_ref()))
            .is_pending()
    );
    drop(pending);
    assert_eq!(writer.write_all(vec![3]).await, [3]);
}
