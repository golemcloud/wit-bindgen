//@ wasmtime-flags = '-Wcomponent-model-async'

include!(env!("BINDINGS"));

use test::outlined_return::values::{get, pages};

struct Component;
export!(Component);

impl Guest for Component {
    async fn run() {
        for _ in 0..32 {
            check().await;
        }
        let warm = pages();
        for _ in 0..256 {
            check().await;
        }
        // Runtime GC may grow by a few pages, but each task.return must release
        // its nested canonical buffers. A missing nested cleanup leaks many MB.
        assert!(pages() <= warm + 16, "nested return buffers leaked");
    }
}

async fn check() {
    let rows = get().await;
    assert_eq!(rows.len(), 1024);
    for (i, row) in rows.into_iter().enumerate() {
        assert_eq!(row.prefix, i as u32);
        assert_eq!(row.value.text, "left λ");
        assert_eq!(row.value.tags, ["right!", "tail"]);
    }
}
