include!(env!("BINDINGS"));

use test::gc_canonical_abi::values::{Payload, echo, pages};

struct Component;
export!(Component);

impl Guest for Component {
    fn run() {
        for _ in 0..8 {
            exercise();
        }
        let warm = pages();
        for _ in 0..256 {
            exercise();
        }
        assert_eq!(
            pages(),
            warm,
            "canonical buffers must be reused after post-return"
        );
    }
}

fn exercise() {
    for len in [0, 3, 257, 65537] {
        let value = Payload {
            text: "\u{feff}árvíz😀\0終𐍈".into(),
            bytes: (0..len).map(|i| ((i * 17 + 3) % 251) as u8).collect(),
            signed_bytes: vec![i8::MIN, -1, 0, 127],
            shorts: vec![i16::MIN, -1, 0, i16::MAX],
            unsigned_shorts: vec![0, 32768, u16::MAX],
            ints: vec![i32::MIN, -1, 0, i32::MAX],
            unsigned_ints: vec![0, 1 << 31, u32::MAX],
            longs: vec![i64::MIN, -1, 0, i64::MAX],
            unsigned_longs: vec![0, 1 << 63, u64::MAX],
            floats: vec![0.0, -0.0, 1.25, f32::INFINITY, f32::NEG_INFINITY],
            doubles: vec![0.0, -0.0, -1.234567890123, f64::INFINITY, f64::NEG_INFINITY],
            bools: vec![true, false, true],
            chars: vec!['\0', 'é', '😀', '\u{10ffff}'],
            nested: vec![None, Some(String::new()), Some("nested😀\0".into())],
        };
        let result = echo(&value);
        assert_eq!(result.text, value.text);
        assert_eq!(result.bytes, value.bytes);
        assert_eq!(result.signed_bytes, value.signed_bytes);
        assert_eq!(result.shorts, value.shorts);
        assert_eq!(result.unsigned_shorts, value.unsigned_shorts);
        assert_eq!(result.ints, value.ints);
        assert_eq!(result.unsigned_ints, value.unsigned_ints);
        assert_eq!(result.longs, value.longs);
        assert_eq!(result.unsigned_longs, value.unsigned_longs);
        assert_eq!(
            result
                .floats
                .iter()
                .map(|v| v.to_bits())
                .collect::<Vec<_>>(),
            value.floats.iter().map(|v| v.to_bits()).collect::<Vec<_>>()
        );
        assert_eq!(
            result
                .doubles
                .iter()
                .map(|v| v.to_bits())
                .collect::<Vec<_>>(),
            value
                .doubles
                .iter()
                .map(|v| v.to_bits())
                .collect::<Vec<_>>()
        );
        assert_eq!(result.bools, value.bools);
        assert_eq!(result.chars, value.chars);
        assert_eq!(result.nested, value.nested);
    }
}
