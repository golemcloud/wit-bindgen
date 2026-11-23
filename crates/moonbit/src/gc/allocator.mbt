///|
/// One allocator owns canonical ABI storage across all generated packages.
/// Metadata lives on the GC heap; payloads live in unshared linear memory.
priv struct Block {
  offset : Int
  mut size : Int
  mut address : Int
  mut available : Bool
  mut next : Block?
}

///|
let blocks : Ref[Block?] = Ref(None)

///|
extern "wasm" fn memory_pages() -> Int =
  #|(func (result i32) memory.size)

///|
extern "wasm" fn grow_memory(pages : Int) -> Int =
  #|(func (param i32) (result i32) local.get 0 memory.grow)

///|
extern "wasm" fn copy(dst : Int, src : Int, len : Int) =
  #|(func (param i32 i32 i32) local.get 0 local.get 1 local.get 2 memory.copy)

///|
fn byte_size(len : Int, width : Int) -> Int {
  guard len >= 0 && len <= 0x7fff0000 / width else {
    abort("canonical ABI allocation is too large")
  }
  len * width
}

///|
pub fn malloc(size : Int) -> Int {
  realloc(0, 0, 16, size)
}

///|
fn allocate(size : Int, alignment : Int) -> Int {
  guard size > 0 && size <= 0x7ffe0000 else {
    abort("canonical ABI allocation is too large")
  }
  guard alignment > 0 && alignment <= 65536 &&
        (alignment & (alignment - 1)) == 0 else {
    abort("invalid canonical ABI alignment")
  }
  if blocks.val is None {
    if memory_pages() == 0 && grow_memory(1) < 0 {
      abort("canonical ABI memory growth failed")
    }
    guard memory_pages() <= 32767 else {
      abort("canonical ABI memory exceeds allocator address range")
    }
    blocks.val = Some({
      offset: 16, size: memory_pages() * 65536 - 16,
      address: 16, available: true, next: None,
    })
  }
  let mut cursor = blocks.val
  while cursor is Some(block) {
    let address = (block.offset + alignment - 1) & (0 - alignment)
    let prefix = address - block.offset
    if block.available && prefix <= block.size && size <= block.size - prefix {
      let used = prefix + size
      if used < block.size {
        block.next = Some({
          offset: block.offset + used, size: block.size - used,
          address: block.offset + used, available: true, next: block.next,
        })
      }
      block.size = used
      block.address = address
      block.available = false
      return address
    }
    if block.next is None {
      let end = memory_pages() * 65536
      let pages = (size + alignment - 1 + 65535) / 65536
      guard pages <= 32767 - memory_pages() && grow_memory(pages) >= 0 else {
        abort("canonical ABI memory growth failed")
      }
      if block.available {
        block.size += pages * 65536
        continue
      }
      block.next = Some({
        offset: end, size: pages * 65536,
        address: end, available: true, next: None,
      })
    }
    cursor = block.next
  }
  abort("canonical ABI allocator has no blocks")
}

///|
pub fn free(ptr : Int) -> Unit {
  if ptr == 0 { return }
  let mut cursor = blocks.val
  let mut found = false
  while cursor is Some(block) {
    if block.address == ptr && !block.available {
      block.available = true
      found = true
      break
    }
    cursor = block.next
  }
  guard found else { abort("invalid canonical ABI free") }
  cursor = blocks.val
  while cursor is Some(block) {
    if block.available && block.next is Some(next) && next.available {
      block.size += next.size
      block.next = next.next
      continue
    }
    cursor = block.next
  }
}

///|
pub fn realloc(src : Int, old_size : Int, alignment : Int, size : Int) -> Int {
  if size == 0 {
    free(src)
    return 0
  }
  let dst = allocate(size, alignment)
  if src != 0 {
    copy(dst, src, if old_size < size { old_size } else { size })
    free(src)
  }
  dst
}
