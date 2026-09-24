use std::sync::Mutex;

static EVENTS: Mutex<Vec<(&str, u32)>> = Mutex::new(Vec::new());

#[derive(Debug)]
pub struct Token(u32);

impl Token {
    pub unsafe fn from_handle(handle: u32) -> Self {
        EVENTS.lock().unwrap().push(("lift", handle));
        Self(handle)
    }
    pub fn take_handle(mut self) -> u32 {
        let handle = self.0;
        EVENTS.lock().unwrap().push(("lower", handle));
        self.0 = u32::MAX;
        handle
    }
}

impl Drop for Token {
    fn drop(&mut self) {
        if self.0 != u32::MAX {
            EVENTS.lock().unwrap().push(("drop", self.0));
        }
    }
}

mod bindings {
    wit_bindgen::generate!({
        inline: r#"
            package test:ownership;
            interface model {
                resource token;
                record leaf { token: own<token>, valid: char, text: string }
                type alias = leaf;
            }
            world test {
                import model;
                use model.{alias};
                export accept: func(values: list<alias>);
                export first: func() -> list<alias>;
                export second: func() -> list<alias>;
            }
        "#,
        with: { "test:ownership/model/token": crate::Token },
        generate_all,
    });
}

struct Component;
impl bindings::Guest for Component {
    fn accept(values: Vec<bindings::Alias>) {
        assert_eq!(values.len(), 2);
        assert_eq!(values[0].valid, 'Q');
        assert_eq!(values[1].valid, 'λ');
    }
    fn first() -> Vec<bindings::Alias> {
        vec![
            bindings::Alias {
                token: Token(17),
                valid: 'Q',
                text: "left".into(),
            },
            bindings::Alias {
                token: Token(83),
                valid: 'λ',
                text: "right".into(),
            },
        ]
    }
    fn second() -> Vec<bindings::Alias> {
        Vec::new()
    }
}

#[repr(C)]
struct RawLeaf {
    handle: u32,
    valid: u32,
    text: *mut u8,
    len: usize,
}

#[repr(C)]
struct RawList {
    ptr: *mut RawLeaf,
    len: usize,
}

#[test]
fn transfer_cleanup_and_partial_lift_failure() {
    // A remapped resource lets this native test observe ownership without host
    // imports. Both exports use the same generated lower/post-return walkers.
    unsafe {
        let ptr = bindings::_export_first_cabi::<Component>();
        let list = &*ptr.cast::<RawList>();
        assert_eq!(list.len, 2);
        let leaves = std::slice::from_raw_parts(list.ptr, list.len);
        assert_eq!((leaves[0].handle, leaves[1].handle), (17, 83));
        assert_eq!(
            std::slice::from_raw_parts(leaves[1].text, leaves[1].len),
            b"right"
        );
        bindings::__post_return_first::<Component>(ptr);
        assert_eq!(*EVENTS.lock().unwrap(), [("lower", 17), ("lower", 83)]);
        let ptr = bindings::_export_second_cabi::<Component>();
        bindings::__post_return_second::<Component>(ptr);

        let raw = vec![
            RawLeaf {
                handle: 29,
                valid: 'Q' as u32,
                text: 1usize as *mut u8,
                len: 0,
            },
            RawLeaf {
                handle: 91,
                valid: 'λ' as u32,
                text: 1usize as *mut u8,
                len: 0,
            },
        ]
        .into_boxed_slice();
        let raw = Box::into_raw(raw).cast::<RawLeaf>();
        bindings::_export_accept_cabi::<Component>(raw.cast(), 2);
        assert_eq!(
            &EVENTS.lock().unwrap()[2..],
            [("lift", 29), ("lift", 91), ("drop", 29), ("drop", 91)]
        );

        // The invalid scalar occurs after acquiring the second handle. A trap
        // must not duplicate either handle transfer. In a native unwinding
        // build, the already lifted values are also dropped once.
        EVENTS.lock().unwrap().clear();
        let raw = vec![
            RawLeaf {
                handle: 31,
                valid: 'Q' as u32,
                text: 1usize as *mut u8,
                len: 0,
            },
            RawLeaf {
                handle: 97,
                valid: 0x11_0000,
                text: 1usize as *mut u8,
                len: 0,
            },
        ]
        .into_boxed_slice();
        let raw = Box::into_raw(raw).cast::<RawLeaf>();
        let result =
            std::panic::catch_unwind(|| bindings::_export_accept_cabi::<Component>(raw.cast(), 2));
        assert!(result.is_err());
        assert_eq!(
            *EVENTS.lock().unwrap(),
            [("lift", 31), ("lift", 97), ("drop", 97), ("drop", 31)]
        );
        // A canonical trap discards the instance, not a recoverable ABI call.
        // The original inline walker also leaves the raw list allocation here.
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(raw, 2)));
    }
}

mod endpoints_and_aliases {
    wit_bindgen::generate!({
        path: "../../tests/codegen/outlined-resources.wit",
        world: "test",
        generate_all,
    });
}

#[test]
fn async_argument_helpers_are_deterministic_and_keep_task_boundaries() {
    fn generate() -> String {
        use wit_bindgen_core::{Files, WorldGenerator, wit_parser::Resolve};
        let mut resolve = Resolve::default();
        let pkg = resolve
            .push_str(
                "test.wit",
                include_str!("../../../tests/codegen/outlined-resources.wit"),
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
        String::from_utf8(files.iter().next().unwrap().1.to_vec()).unwrap()
    }
    let source = generate();
    assert_eq!(source, generate());
    for body in source.split("pub unsafe fn _export_consume_cabi").skip(1) {
        let body = body
            .split("pub unsafe fn __callback_consume")
            .next()
            .unwrap();
        assert_eq!(body.matches("TaskCancelOnDrop::new()").count(), 1);
        assert_eq!(body.matches("__wit_bindgen_lift_").count(), 2);
        assert!(body.contains("::start_task(async move"));
        assert!(body.contains("::consume("));
        assert!(body.contains(".await"));
        assert!(!body.contains("from_handle"));
    }
    assert_eq!(
        source.matches("pub unsafe fn _export_consume_cabi").count(),
        2
    );
    for body in source.split("unsafe fn __wit_bindgen_deallocate_").skip(1) {
        let body = body.split("unsafe fn ").next().unwrap();
        assert!(!body.contains("from_handle"));
        assert!(!body.contains("take_handle"));
    }
}

mod borrowed_result {
    wit_bindgen::generate!({
        inline: r#"
            package test:borrowed-result;
            world test {
                record leaf { text: string }
                record graph { leaves: list<leaf>, tail: string }
                export get: async func() -> graph;
            }
        "#,
    });

    #[repr(C)]
    struct RawString {
        ptr: *const u8,
        len: usize,
    }
    #[repr(C)]
    struct RawGraph {
        leaves: *const RawString,
        len: usize,
        tail: RawString,
    }

    #[test]
    fn borrowed_lowering_keeps_scratch_until_task_return() {
        let value = Graph {
            leaves: vec![
                Leaf {
                    text: "left".into(),
                },
                Leaf {
                    text: "right!".into(),
                },
            ],
            tail: "tail".into(),
        };
        let mut raw = std::mem::MaybeUninit::<RawGraph>::uninit();
        let mut cleanup = Vec::new();
        unsafe {
            __wit_bindgen_borrow_lower_t2(raw.as_mut_ptr().cast(), &value, &mut cleanup);
            // Only the non-canonical list needs a temporary allocation. Strings
            // borrow the original result, which also survives through task.return.
            assert_eq!(cleanup.len(), 1);
            let raw = raw.assume_init();
            assert_eq!(raw.len, 2);
            let leaves = std::slice::from_raw_parts(raw.leaves, raw.len);
            assert_eq!(
                std::slice::from_raw_parts(leaves[0].ptr, leaves[0].len),
                b"left"
            );
            assert_eq!(
                std::slice::from_raw_parts(leaves[1].ptr, leaves[1].len),
                b"right!"
            );
            assert_eq!(raw.tail.ptr, value.tail.as_ptr());
            assert_eq!(raw.tail.len, 4);
        }
        drop(cleanup);
        assert_eq!(value.leaves[1].text, "right!");
    }
}
