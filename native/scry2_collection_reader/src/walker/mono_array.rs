//! Generic `MonoArray<T>` reader — header validation + element blob.
//!
//! Every Mono `T[]` carries a 32-byte header on x86-64:
//!
//! ```text
//! +0x00  obj          : MonoObject
//! +0x10  bounds       : MonoArrayBounds *      (null for vectors)
//! +0x18  max_length   : uintptr (capacity)
//! +0x20  vector[]     : T elements (flex)
//! ```
//!
//! Until this module existed, three callers (`dict`, `dict_kv`,
//! `list_t`) carried their own copies of the same `read_header →
//! check_capacity → read_blob` sequence (audit finding 2.3).
//!
//! [`read_array_blob`] returns `(capacity, blob)` or `None` if the
//! header read fails, the capacity exceeds the caller-supplied cap,
//! or the blob read fails. Callers do not see the header bytes — the
//! function returns only the raw element storage so the same code
//! drives every fixed-size-element walker.

use super::mono::{self, MonoOffsets};

/// Read a `MonoArray<T>` header at `array_addr`, validate
/// `max_length <= max_elements`, then read `capacity * element_size`
/// bytes of element storage.
///
/// Returns:
/// - `None` if the header cannot be read, the bytes are short, the
///   capacity exceeds `max_elements`, the blob length overflows `usize`,
///   or the bulk read returns `None` / short.
/// - `Some((0, Vec::new()))` for a valid empty array.
/// - `Some((capacity, blob))` otherwise. `blob.len()` is exactly
///   `capacity * element_size`.
pub fn read_array_blob<F>(
    offsets: &MonoOffsets,
    array_addr: u64,
    element_size: usize,
    max_elements: u64,
    read_mem: &F,
) -> Option<(usize, Vec<u8>)>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let header_len = offsets.array_vector;
    let header = read_mem(array_addr, header_len)?;
    if header.len() < header_len {
        return None;
    }
    let capacity = mono::array_max_length(offsets, &header, 0)?;
    if capacity == 0 {
        return Some((0, Vec::new()));
    }
    if capacity > max_elements {
        return None;
    }
    let capacity = capacity as usize;

    let vector_addr = mono::array_vector_addr(offsets, array_addr)?;
    let blob_len = capacity.checked_mul(element_size)?;
    let blob = read_mem(vector_addr, blob_len)?;
    if blob.len() < blob_len {
        return None;
    }
    Some((capacity, blob))
}

/// Read a `MonoArray<T>` whose elements are inline values, returning
/// the raw element storage capped at `max_elements`. Used by `List<T>`
/// walkers where the size comes from the list header (not the array
/// header).
///
/// `count` is the number of elements to read — the caller should pass
/// `min(list._size, max_elements)` so the bulk read is bounded.
pub fn read_array_elements<F>(
    array_addr: u64,
    vector_offset: u64,
    count: usize,
    element_size: usize,
    read_mem: &F,
) -> Option<Vec<u8>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let elements_addr = array_addr.checked_add(vector_offset)?;
    let blob_len = count.checked_mul(element_size)?;
    let blob = read_mem(elements_addr, blob_len)?;
    if blob.len() < blob_len {
        return None;
    }
    Some(blob)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::test_support::FakeMem;

    fn write_array_header(mem: &mut FakeMem, addr: u64, capacity: u64, vector: Vec<u8>) {
        let offsets = MonoOffsets::mtga_default();
        let mut hdr = vec![0u8; offsets.array_vector];
        hdr[offsets.array_max_length..offsets.array_max_length + 8]
            .copy_from_slice(&capacity.to_le_bytes());
        mem.add(addr, hdr);
        mem.add(addr + offsets.array_vector as u64, vector);
    }

    #[test]
    fn read_array_blob_returns_capacity_and_storage() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let array_addr: u64 = 0x10_0000;
        let elements: Vec<u8> = (0..16).collect();
        write_array_header(&mut mem, array_addr, 4, elements.clone());

        let (cap, blob) = read_array_blob(&offsets, array_addr, 4, 100, &|a, l| mem.read(a, l))
            .ok_or("must read")?;
        assert_eq!(cap, 4);
        assert_eq!(blob, elements);
        Ok(())
    }

    #[test]
    fn read_array_blob_returns_none_when_capacity_exceeds_cap() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let array_addr: u64 = 0x10_0000;
        write_array_header(&mut mem, array_addr, 5_000, vec![]);

        let result = read_array_blob(&offsets, array_addr, 4, 100, &|a, l| mem.read(a, l));
        assert!(result.is_none());
    }

    #[test]
    fn read_array_blob_returns_zero_capacity_empty_vec_for_empty_array() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let array_addr: u64 = 0x10_0000;
        write_array_header(&mut mem, array_addr, 0, vec![]);

        let (cap, blob) = read_array_blob(&offsets, array_addr, 4, 100, &|a, l| mem.read(a, l))
            .ok_or("must read")?;
        assert_eq!(cap, 0);
        assert!(blob.is_empty());
        Ok(())
    }

    #[test]
    fn read_array_blob_returns_none_when_header_unreadable() {
        let offsets = MonoOffsets::mtga_default();
        let mem = FakeMem::default();
        let result = read_array_blob(&offsets, 0xdead_0000, 4, 100, &|a, l| mem.read(a, l));
        assert!(result.is_none());
    }

    #[test]
    fn read_array_elements_returns_bulk_blob() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let array_addr: u64 = 0x10_0000;
        let elements: Vec<u8> = (0..32).collect();
        mem.add(array_addr + 0x20, elements.clone());

        let blob =
            read_array_elements(array_addr, 0x20, 4, 4, &|a, l| mem.read(a, l)).ok_or("must")?;
        assert_eq!(blob, elements[..16]);
        Ok(())
    }

    #[test]
    fn read_array_elements_returns_none_when_overflow() {
        let mem = FakeMem::default();
        let result = read_array_elements(u64::MAX - 4, 0x20, 1, 4, &|a, l| mem.read(a, l));
        assert!(result.is_none());
    }
}
