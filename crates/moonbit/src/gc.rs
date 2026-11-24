use crate::ffi;

const ARRAYS: [(&str, &str, &str, usize); 7] = [
    ("bytes", "FixedArray[Byte]", "i32", 1),
    ("uint_array", "FixedArray[UInt]", "i32", 4),
    ("int_array", "FixedArray[Int]", "i32", 4),
    ("uint64_array", "FixedArray[UInt64]", "i64", 8),
    ("int64_array", "FixedArray[Int64]", "i64", 8),
    ("float_array", "FixedArray[Float]", "f32", 4),
    ("double_array", "FixedArray[Double]", "f64", 8),
];

pub(crate) fn builtin(source: &str) -> Option<String> {
    let (name, params, result, arguments) = match source {
        ffi::MALLOC => ("malloc", "size : Int", "Int", "size"),
        ffi::FREE => ("free", "ptr : Int", "Unit", "ptr"),
        ffi::CABI_REALLOC => {
            return Some("///|\npub fn mbt_ffi_cabi_realloc(src : Int, old_size : Int, alignment : Int, size : Int) -> Int { @witCabi.realloc(src, old_size, alignment, size) }\n".into());
        }
        ffi::STR2PTR => ("str2ptr", "value : String", "Int", "value"),
        ffi::PTR2STR => ("ptr2str", "ptr : Int, len : Int", "String", "ptr, len"),
        _ => {
            for ((name, ty, _, _), (lower, lift)) in ARRAYS.iter().zip([
                (ffi::BYTES2PTR, ffi::PTR2BYTES),
                (ffi::UINT_ARRAY2PTR, ffi::PTR2UINT_ARRAY),
                (ffi::INT_ARRAY2PTR, ffi::PTR2INT_ARRAY),
                (ffi::UINT64_ARRAY2PTR, ffi::PTR2UINT64_ARRAY),
                (ffi::INT64_ARRAY2PTR, ffi::PTR2INT64_ARRAY),
                (ffi::FLOAT_ARRAY2PTR, ffi::PTR2FLOAT_ARRAY),
                (ffi::DOUBLE_ARRAY2PTR, ffi::PTR2DOUBLE_ARRAY),
            ]) {
                if source == lower {
                    return Some(format!(
                        "///|\nfn mbt_ffi_{name}2ptr(value : {ty}) -> Int {{ @witCabi.{name}2ptr(value) }}\n"
                    ));
                }
                if source == lift {
                    return Some(format!(
                        "///|\nfn mbt_ffi_ptr2{name}(ptr : Int, len : Int) -> {ty} {{ @witCabi.ptr2{name}(ptr, len) }}\n"
                    ));
                }
            }
            return None;
        }
    };
    Some(format!(
        "///|\nfn mbt_ffi_{name}({params}) -> {result} {{ @witCabi.{name}({arguments}) }}\n"
    ))
}

pub(crate) fn runtime() -> String {
    let mut source = include_str!("gc/allocator.mbt").to_string();
    for (name, ty, wasm_ty, width) in ARRAYS {
        if width == 1 {
            source.push_str(include_str!("gc/bytes.mbt"));
            continue;
        }
        let element = ty
            .strip_prefix("FixedArray[")
            .unwrap()
            .strip_suffix(']')
            .unwrap();
        source.push_str(&format!(
            r#"
///|
extern "wasm" fn load_{name}(ptr : Int) -> {element} =
  #|(func (param i32) (result {wasm_ty}) local.get 0 {wasm_ty}.load)
///|
extern "wasm" fn store_{name}(ptr : Int, value : {element}) =
  #|(func (param i32 {wasm_ty}) local.get 0 local.get 1 {wasm_ty}.store)
///|
pub fn {name}2ptr(value : {ty}) -> Int {{
  let ptr = malloc(byte_size(value.length(), {width}))
  for i in 0..<value.length() {{ store_{name}(ptr + i * {width}, value[i]) }}
  ptr
}}
///|
pub fn ptr2{name}(ptr : Int, len : Int) -> {ty} {{
  ignore(byte_size(len, {width}))
  FixedArray::makei(len, i => load_{name}(ptr + i * {width}))
}}
"#
        ));
    }
    source.push_str(
        r#"
///|
pub fn str2ptr(value : String) -> Int {
  let ptr = malloc(byte_size(value.length(), 2))
  for i in 0..<value.length() { store16(ptr + i * 2, value[i].to_int()) }
  ptr
}
///|
pub fn ptr2str(ptr : Int, len : Int) -> String {
  let bytes = Bytes::makei(byte_size(len, 2), i => load_bytes(ptr + i).to_byte())
  try! @utf16.decode(bytes, ignore_bom=false)
}
///|
extern "wasm" fn store16(ptr : Int, value : Int) =
  #|(func (param i32 i32) local.get 0 local.get 1 i32.store16)
"#,
    );
    source
}
