use wit_bindgen_core::{Files, WorldGenerator, wit_parser::Resolve};

#[test]
fn export_lower_helpers_are_shared_and_ownership_scoped() {
    let mut resolve = Resolve::default();
    let pkg = resolve
        .push_str(
            "outlined-lowering.wit",
            include_str!("../../../tests/codegen/outlined-lowering.wit"),
        )
        .unwrap();
    let world = resolve.select_world(&[pkg], Some("test")).unwrap();
    let mut files = Files::default();
    wit_bindgen_rust::Opts {
        generate_all: true,
        ..Default::default()
    }
    .build()
    .generate(&mut resolve, world, &mut files)
    .unwrap();
    let (_, source) = files.iter().next().unwrap();
    let source = std::str::from_utf8(source).unwrap();
    assert_eq!(source.matches("unsafe fn __wit_bindgen_lower_").count(), 5);
    let (imports, exports) = source.split_once("pub mod exports").unwrap();
    assert!(!imports.contains("__wit_bindgen_lower_"));
    assert!(exports.contains("#[inline(never)]"));
    let async_export = exports
        .split_once("fn _export_get_later_cabi")
        .unwrap()
        .1
        .split("pub unsafe fn")
        .next()
        .unwrap();
    assert!(!async_export.contains("__wit_bindgen_lower_"));
    for name in [
        "SchemaType",
        "SchemaTypeBody",
        "SchemaGraph",
        "Tool",
        "AgentType",
    ] {
        assert!(exports.contains(&format!("::{name})")), "{name}");
    }
    // Golden call sites: nested records and variant payloads must preserve
    // pointer-sized offsets, not overwrite their enclosing discriminants.
    assert!(
        exports
            .contains("__wit_bindgen_lower_t1(ptr.add(::core::mem::size_of::<*const u8>()), e);")
    );
    assert!(exports.contains(
        "__wit_bindgen_lower_t5(ptr.add(2*::core::mem::size_of::<*const u8>()), schema0);"
    ));
    assert!(exports.contains("__wit_bindgen_lower_t7(base.add(0), e);"));
}

// Compile aliases, borrowed imports, cross-interface types, resource-containing
// results and nested payload vtables with both Rust ownership policies.
mod owning {
    wit_bindgen::generate!({
        path: "../../tests/codegen/outlined-lowering.wit",
        world: "test",
        generate_all,
    });
}

mod borrowing {
    wit_bindgen::generate!({
        path: "../../tests/codegen/outlined-lowering.wit",
        world: "test",
        generate_all,
        ownership: Borrowing { duplicate_if_necessary: true },
    });
}

mod memory {
    wit_bindgen::generate!({
        inline: r#"
            package test:memory;
            world test {
                record leaf { name: string, numbers: list<u32> }
                variant node { empty, leaves(list<leaf>) }
                record graph { prefix: u32, body: node, suffix: string }
                export first: func() -> graph;
                export second: func() -> graph;
            }
        "#,
    });

    struct Component;
    impl Guest for Component {
        fn first() -> Graph {
            Graph {
                prefix: 0x12345678,
                body: Node::Leaves(vec![
                    Leaf {
                        name: "left".into(),
                        numbers: vec![7, 19, 300],
                    },
                    Leaf {
                        name: "right!".into(),
                        numbers: vec![42],
                    },
                ]),
                suffix: "tail".into(),
            }
        }
        fn second() -> Graph {
            Graph {
                prefix: 91,
                body: Node::Empty,
                suffix: "other".into(),
            }
        }
    }

    #[repr(C)]
    struct RawList<T> {
        ptr: *const T,
        len: usize,
    }
    #[repr(C)]
    struct RawLeaf {
        name: RawList<u8>,
        numbers: RawList<u32>,
    }
    #[repr(C)]
    struct RawNode {
        tag: u8,
        leaves: RawList<RawLeaf>,
    }
    #[repr(C)]
    struct RawGraph {
        prefix: u32,
        body: RawNode,
        suffix: RawList<u8>,
    }

    #[test]
    fn owned_lowering_preserves_layout_and_post_return() {
        // Independent repr(C) layout for canonical strings/lists and a variant
        // with one list payload. Run serially: exports share a return area.
        unsafe {
            let ptr = _export_first_cabi::<Component>();
            let graph = &*ptr.cast::<RawGraph>();
            assert_eq!(graph.prefix, 0x12345678);
            assert_eq!(graph.body.tag, 1);
            assert_eq!(graph.body.leaves.len, 2);
            let leaves = std::slice::from_raw_parts(graph.body.leaves.ptr, 2);
            assert_eq!(
                std::slice::from_raw_parts(leaves[0].name.ptr, leaves[0].name.len),
                b"left"
            );
            assert_eq!(
                std::slice::from_raw_parts(leaves[1].name.ptr, leaves[1].name.len),
                b"right!"
            );
            assert_eq!(
                std::slice::from_raw_parts(leaves[0].numbers.ptr, leaves[0].numbers.len),
                &[7, 19, 300]
            );
            assert_eq!(
                std::slice::from_raw_parts(leaves[1].numbers.ptr, leaves[1].numbers.len),
                &[42]
            );
            assert_eq!(
                std::slice::from_raw_parts(graph.suffix.ptr, graph.suffix.len),
                b"tail"
            );
            __post_return_first::<Component>(ptr);

            let ptr = _export_second_cabi::<Component>();
            // The empty case leaves its payload uninitialized; do not form a
            // reference to a RawGraph that pretends the payload is valid.
            let graph = ptr.cast::<RawGraph>();
            assert_eq!((*graph).prefix, 91);
            assert_eq!((*graph).body.tag, 0);
            assert_eq!(
                std::slice::from_raw_parts((*graph).suffix.ptr, (*graph).suffix.len),
                b"other"
            );
            __post_return_second::<Component>(ptr);
        }
    }
}
