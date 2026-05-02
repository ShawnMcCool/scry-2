//! Locate a `MonoClass *` by name in a `MonoImage.class_cache`.
//!
//! Each `MonoImage` carries an embedded `MonoInternalHashTable` at
//! offset `image_class_cache` whose buckets store every `MonoClass *`
//! that image owns. The hash table is keyed on a private hash of
//! `(name_space, name)`, and chained via `MonoClassDef.next_class_cache`
//! at offset `class_def_next_class_cache`.
//!
//! We **don't** invoke the table's hash function — `hash_func`,
//! `key_extract`, and `next_value` are function pointers into the
//! target process and we can't `call` them remotely. Instead we
//! linearly scan every bucket and every chain entry, comparing
//! `MonoClass.name` to the target. MTGA's `Core.dll` has a few
//! thousand classes total — a one-shot startup scan is fine.
//!
//! This module's `find_class_by_name` mirrors the shape of
//! `field::find_field_by_name` and `image_lookup::find_image_by_name`:
//! it takes a `read_mem` closure so the same code drives both live
//! `process_vm_readv` reads and `FakeMem`-style unit tests.

use super::limits::{MAX_BUCKETS, MAX_NAME_LEN, MAX_TOTAL_CLASSES};
use super::mono::{self, MonoOffsets, POINTER_SIZE};

/// Walk `image->class_cache` and return every class name +
/// `MonoClass *` it visits. Useful for diagnostics when looking for
/// a class whose exact name is unknown (e.g. searching for any
/// class containing "Inventory" or "Wrapper" across an MTGA build).
pub fn list_all_classes<F>(
    offsets: &MonoOffsets,
    image_addr: u64,
    read_mem: F,
) -> Option<Vec<(String, u64)>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let cache_addr = mono::image_class_cache_addr(offsets, image_addr)?;
    let header = read_mem(cache_addr, hash_table_header_size(offsets))?;
    let size = mono::hash_table_size(offsets, &header, 0)?;
    if size <= 0 {
        return Some(Vec::new());
    }
    let size = size as usize;
    if size > MAX_BUCKETS {
        return Some(Vec::new());
    }
    let table_ptr = mono::hash_table_table_ptr(offsets, &header, 0)?;
    if table_ptr == 0 {
        return Some(Vec::new());
    }

    let mut out = Vec::new();
    let mut visited = 0usize;
    for bucket_idx in 0..size {
        let bucket_slot_addr =
            table_ptr.checked_add((bucket_idx as u64).checked_mul(POINTER_SIZE as u64)?)?;
        let bucket_buf = match read_mem(bucket_slot_addr, POINTER_SIZE) {
            Some(b) => b,
            None => continue,
        };
        let mut node = match mono::read_ptr(&bucket_buf, 0, 0) {
            Some(p) => p,
            None => continue,
        };
        while node != 0 {
            visited += 1;
            if visited > MAX_TOTAL_CLASSES {
                return Some(out);
            }

            if let Some(name) = read_class_name(offsets, node, &read_mem) {
                out.push((name, node));
            }

            node = match read_next_class_cache(offsets, node, &read_mem) {
                Some(n) => n,
                None => break,
            };
        }
    }
    Some(out)
}

/// Read `MonoClass.name` as a UTF-8-best-effort string. Returns
/// `None` only on a read failure that prevents the read.
fn read_class_name<F>(offsets: &MonoOffsets, class_addr: u64, read_mem: &F) -> Option<String>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let name_slot = class_addr.checked_add(offsets.class_name as u64)?;
    let name_ptr_buf = read_mem(name_slot, POINTER_SIZE)?;
    let name_ptr = mono::read_ptr(&name_ptr_buf, 0, 0)?;
    if name_ptr == 0 {
        return None;
    }
    let buf = read_mem(name_ptr, MAX_NAME_LEN)?;
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    Some(String::from_utf8_lossy(&buf[..end]).into_owned())
}

/// Walk `image->class_cache` and return the `MonoClass *` for the
/// first class whose `name` matches `target_name` (exact bytewise
/// comparison; `target_name` carries no trailing NUL).
///
/// Returns `None` when:
/// - The hash-table header (`size` / `table` ptr) cannot be read.
/// - The bucket array head is null.
/// - `size` is zero or exceeds `MAX_BUCKETS`.
/// - `MAX_TOTAL_CLASSES` chain dereferences are exhausted.
/// - No class matches `target_name`.
///
/// A read miss on an individual bucket head, chain node, or class
/// name is treated as "skip this entry" — iteration continues to
/// the next bucket. This mirrors the posture of `field::find_field_by_name`
/// and `image_lookup::find_image_by_name`.
///
/// `read_mem(addr, len)` fetches `len` bytes from the target process
/// at remote address `addr`. In tests this is a `FakeMem`-style stub.
pub fn find_class_by_name<F>(
    offsets: &MonoOffsets,
    image_addr: u64,
    target_name: &str,
    read_mem: F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let cache_addr = mono::image_class_cache_addr(offsets, image_addr)?;
    let header = read_mem(cache_addr, hash_table_header_size(offsets))?;
    let size = mono::hash_table_size(offsets, &header, 0)?;
    if size <= 0 {
        return None;
    }
    let size = size as usize;
    if size > MAX_BUCKETS {
        return None;
    }
    let table_ptr = mono::hash_table_table_ptr(offsets, &header, 0)?;
    if table_ptr == 0 {
        return None;
    }

    let target_bytes = target_name.as_bytes();
    let mut visited = 0usize;
    for bucket_idx in 0..size {
        let bucket_slot_addr =
            table_ptr.checked_add((bucket_idx as u64).checked_mul(POINTER_SIZE as u64)?)?;
        let bucket_buf = match read_mem(bucket_slot_addr, POINTER_SIZE) {
            Some(b) => b,
            None => continue,
        };
        let mut node = match mono::read_ptr(&bucket_buf, 0, 0) {
            Some(p) => p,
            None => continue,
        };
        while node != 0 {
            visited += 1;
            if visited > MAX_TOTAL_CLASSES {
                return None;
            }

            if class_name_matches(offsets, node, target_bytes, &read_mem).unwrap_or(false) {
                return Some(node);
            }

            node = match read_next_class_cache(offsets, node, &read_mem) {
                Some(n) => n,
                None => break, // unreadable chain — skip rest of this bucket
            };
        }
    }
    None
}

/// Number of bytes covering the part of `MonoInternalHashTable` the
/// walker reads: from offset 0 through the end of the `table`
/// pointer. We don't need the function-pointer fields, but reading
/// the whole prefix in one call keeps the FakeMem fixtures simple.
fn hash_table_header_size(offsets: &MonoOffsets) -> usize {
    offsets.hash_table_table + POINTER_SIZE
}

/// Return whether the class at `class_addr` has a `name` matching
/// `target_bytes`. `Some(false)` on a definite mismatch, `Some(true)`
/// on match, `None` on a read failure that prevents the comparison.
fn class_name_matches<F>(
    offsets: &MonoOffsets,
    class_addr: u64,
    target_bytes: &[u8],
    read_mem: &F,
) -> Option<bool>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let name_slot = class_addr.checked_add(offsets.class_name as u64)?;
    let name_ptr_buf = read_mem(name_slot, POINTER_SIZE)?;
    let name_ptr = mono::read_ptr(&name_ptr_buf, 0, 0)?;
    if name_ptr == 0 {
        return Some(false);
    }
    let name_buf = read_mem(name_ptr, MAX_NAME_LEN)?;
    let end = name_buf
        .iter()
        .position(|&b| b == 0)
        .unwrap_or(name_buf.len());
    Some(&name_buf[..end] == target_bytes)
}

/// Read `MonoClassDef.next_class_cache` from the chain entry at
/// `class_addr`. Returns `Some(0)` when the chain ends; `None` when
/// the read fails.
fn read_next_class_cache<F>(offsets: &MonoOffsets, class_addr: u64, read_mem: &F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let slot = class_addr.checked_add(offsets.class_def_next_class_cache as u64)?;
    let buf = read_mem(slot, POINTER_SIZE)?;
    mono::read_ptr(&buf, 0, 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::walker::test_support::FakeMem;

    /// Layout knobs for the synthetic image fixtures. Picking widely
    /// spaced base addresses keeps the FakeMem block lookups
    /// unambiguous (no "address 0x100 falls in the 0x80-sized block
    /// at 0x80" overlap surprises).
    const IMAGE_ADDR: u64 = 0x1_0000_0000;
    const TABLE_PTR: u64 = 0x2_0000_0000;
    const CLASS_BASE: u64 = 0x3_0000_0000;
    const NAME_BASE: u64 = 0x4_0000_0000;
    const CLASS_STRIDE: u64 = 0x1000;
    const NAME_STRIDE: u64 = 0x100;

    /// Write the embedded `MonoInternalHashTable` header inside an
    /// image block (at the image's class_cache offset).
    fn write_image_with_table(mem: &mut FakeMem, size: i32, num_entries: i32, table: u64) {
        let offsets = MonoOffsets::mtga_default();
        let mut image = vec![0u8; offsets.image_class_cache + hash_table_header_size(&offsets)];
        let table_off = offsets.image_class_cache;
        image[table_off + offsets.hash_table_size..table_off + offsets.hash_table_size + 4]
            .copy_from_slice(&(size as u32).to_le_bytes());
        image[table_off + offsets.hash_table_num_entries
            ..table_off + offsets.hash_table_num_entries + 4]
            .copy_from_slice(&(num_entries as u32).to_le_bytes());
        image[table_off + offsets.hash_table_table..table_off + offsets.hash_table_table + 8]
            .copy_from_slice(&table.to_le_bytes());
        mem.add(IMAGE_ADDR, image);
    }

    /// Write the bucket-pointer array (heap-allocated `gpointer[]`).
    /// `bucket_heads[i]` is the chain head address for bucket i (0
    /// means empty bucket).
    fn write_bucket_array(mem: &mut FakeMem, bucket_heads: &[u64]) {
        let mut buf = Vec::with_capacity(bucket_heads.len() * POINTER_SIZE);
        for h in bucket_heads {
            buf.extend_from_slice(&h.to_le_bytes());
        }
        mem.add(TABLE_PTR, buf);
    }

    /// Write a single MonoClassDef entry: a synthetic block at
    /// `class_addr` carrying a `name` ptr at offset 0x48 (pointing
    /// at `NAME_BASE + name_idx * 0x100`) and a `next_class_cache`
    /// ptr at offset 0x108 (pointing at `next`). Also writes the
    /// NUL-terminated name string at the name pointer.
    fn write_class(mem: &mut FakeMem, class_addr: u64, name: &str, name_idx: u64, next: u64) {
        let offsets = MonoOffsets::mtga_default();
        let block_size = offsets.class_def_next_class_cache + POINTER_SIZE;
        let mut block = vec![0u8; block_size];
        let name_ptr = NAME_BASE + name_idx * NAME_STRIDE;
        block[offsets.class_name..offsets.class_name + 8].copy_from_slice(&name_ptr.to_le_bytes());
        block[offsets.class_def_next_class_cache..offsets.class_def_next_class_cache + 8]
            .copy_from_slice(&next.to_le_bytes());
        mem.add(class_addr, block);

        let mut name_bytes = name.as_bytes().to_vec();
        name_bytes.push(0);
        mem.add(name_ptr, name_bytes);
    }

    /// Compose: 1 image, N buckets each with M chained classes.
    /// `entries[bucket_idx]` is the list of `(class_name, name_idx)`
    /// to put in that bucket. Returns the addresses assigned to each
    /// class so tests can assert on the right one.
    fn build_image(mem: &mut FakeMem, entries: &[Vec<&str>]) -> Vec<u64> {
        let size = entries.len() as i32;
        let total_count: i32 = entries.iter().map(|c| c.len() as i32).sum();
        write_image_with_table(mem, size, total_count, TABLE_PTR);

        let mut next_class_idx: u64 = 0;
        let mut next_name_idx: u64 = 0;
        let mut bucket_heads: Vec<u64> = Vec::with_capacity(entries.len());
        let mut emitted_addrs: Vec<u64> = Vec::new();

        for chain in entries {
            if chain.is_empty() {
                bucket_heads.push(0);
                continue;
            }

            // Pre-compute the addresses assigned to this chain.
            let chain_addrs: Vec<u64> = (0..chain.len())
                .map(|i| CLASS_BASE + (next_class_idx + i as u64) * CLASS_STRIDE)
                .collect();

            for (i, name) in chain.iter().enumerate() {
                let next = chain_addrs.get(i + 1).copied().unwrap_or(0);
                write_class(mem, chain_addrs[i], name, next_name_idx, next);
                emitted_addrs.push(chain_addrs[i]);
                next_name_idx += 1;
            }
            bucket_heads.push(chain_addrs[0]);
            next_class_idx += chain.len() as u64;
        }

        write_bucket_array(mem, &bucket_heads);
        emitted_addrs
    }

    fn run(mem: &FakeMem, target: &str) -> Option<u64> {
        let offsets = MonoOffsets::mtga_default();
        find_class_by_name(&offsets, IMAGE_ADDR, target, |addr, len| {
            mem.read(addr, len)
        })
    }

    #[test]
    fn finds_class_in_first_bucket() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let addrs = build_image(&mut mem, &[vec!["PAPA", "Other"], vec!["Misc"]]);
        let hit = run(&mem, "PAPA").ok_or("PAPA should resolve")?;
        assert_eq!(hit, addrs[0]);
        Ok(())
    }

    #[test]
    fn finds_class_deeper_in_chain() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let addrs = build_image(&mut mem, &[vec!["A", "B", "PAPA", "C"]]);
        let hit = run(&mem, "PAPA").ok_or("PAPA should resolve mid-chain")?;
        assert_eq!(hit, addrs[2]);
        Ok(())
    }

    #[test]
    fn finds_class_in_later_bucket() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let addrs = build_image(
            &mut mem,
            &[vec!["alpha"], vec![], vec!["beta", "gamma"], vec!["PAPA"]],
        );
        let hit = run(&mem, "PAPA").ok_or("PAPA should resolve in bucket 3")?;
        // Skipping empty bucket: addrs are ordered by emission, so:
        //  addrs[0] = alpha (bucket 0)
        //  addrs[1] = beta  (bucket 2)
        //  addrs[2] = gamma (bucket 2)
        //  addrs[3] = PAPA  (bucket 3)
        assert_eq!(hit, addrs[3]);
        Ok(())
    }

    #[test]
    fn returns_none_when_no_class_matches() {
        let mut mem = FakeMem::default();
        build_image(&mut mem, &[vec!["alpha", "beta"], vec!["gamma"]]);
        assert_eq!(run(&mem, "PAPA"), None);
    }

    #[test]
    fn returns_none_when_size_is_zero() {
        let mut mem = FakeMem::default();
        write_image_with_table(&mut mem, 0, 0, TABLE_PTR);
        write_bucket_array(&mut mem, &[]);
        assert_eq!(run(&mem, "anything"), None);
    }

    #[test]
    fn returns_none_when_size_is_negative() {
        let mut mem = FakeMem::default();
        write_image_with_table(&mut mem, -1, 0, TABLE_PTR);
        assert_eq!(run(&mem, "anything"), None);
    }

    #[test]
    fn returns_none_when_size_exceeds_max_buckets() {
        let mut mem = FakeMem::default();
        write_image_with_table(&mut mem, (MAX_BUCKETS + 1) as i32, 0, TABLE_PTR);
        assert_eq!(run(&mem, "anything"), None);
    }

    #[test]
    fn returns_none_when_table_pointer_is_null() {
        let mut mem = FakeMem::default();
        write_image_with_table(&mut mem, 16, 0, 0);
        assert_eq!(run(&mem, "anything"), None);
    }

    #[test]
    fn returns_none_when_image_address_unreadable() {
        let mem = FakeMem::default();
        assert_eq!(run(&mem, "anything"), None);
    }

    #[test]
    fn name_match_is_exact_no_prefix_match() -> Result<(), String> {
        let mut mem = FakeMem::default();
        // Looking for "PAPA" should NOT match "PAPALite" or "MyPAPA".
        let addrs = build_image(&mut mem, &[vec!["PAPALite", "MyPAPA", "PAPA"]]);
        let hit = run(&mem, "PAPA").ok_or("exact PAPA must still match")?;
        assert_eq!(hit, addrs[2]);
        Ok(())
    }

    #[test]
    fn skips_class_with_unreadable_name_pointer() -> Result<(), String> {
        // First entry has a name pointer that points outside FakeMem.
        // The walker should skip it and continue to the next.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        let cls0 = CLASS_BASE;
        let cls1 = CLASS_BASE + CLASS_STRIDE;
        let bad_name_ptr: u64 = 0x9999_9999_9999_9999;

        write_image_with_table(&mut mem, 1, 2, TABLE_PTR);
        write_bucket_array(&mut mem, &[cls0]);

        // First class — bad name ptr, chain to cls1.
        let block_size = offsets.class_def_next_class_cache + POINTER_SIZE;
        let mut block0 = vec![0u8; block_size];
        block0[offsets.class_name..offsets.class_name + 8]
            .copy_from_slice(&bad_name_ptr.to_le_bytes());
        block0[offsets.class_def_next_class_cache..offsets.class_def_next_class_cache + 8]
            .copy_from_slice(&cls1.to_le_bytes());
        mem.add(cls0, block0);

        // Second class — valid name "PAPA", end of chain.
        write_class(&mut mem, cls1, "PAPA", 1, 0);

        let hit = run(&mem, "PAPA").ok_or("walker must reach cls1 after skipping cls0")?;
        assert_eq!(hit, cls1);
        Ok(())
    }

    #[test]
    fn caps_total_iteration_on_chain_cycle() {
        // Construct a one-class self-cycle (next_class_cache → self).
        // The walker must terminate via MAX_TOTAL_CLASSES rather than
        // spin forever.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let cls = CLASS_BASE;

        write_image_with_table(&mut mem, 1, 1, TABLE_PTR);
        write_bucket_array(&mut mem, &[cls]);

        let block_size = offsets.class_def_next_class_cache + POINTER_SIZE;
        let mut block = vec![0u8; block_size];
        let name_ptr = NAME_BASE;
        block[offsets.class_name..offsets.class_name + 8].copy_from_slice(&name_ptr.to_le_bytes());
        // next = self → cycle
        block[offsets.class_def_next_class_cache..offsets.class_def_next_class_cache + 8]
            .copy_from_slice(&cls.to_le_bytes());
        mem.add(cls, block);

        let mut nm = b"NotMatching".to_vec();
        nm.push(0);
        mem.add(name_ptr, nm);

        // Must terminate without panicking and return None.
        assert_eq!(run(&mem, "PAPA"), None);
    }

    #[test]
    fn skips_empty_buckets_cleanly() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let addrs = build_image(&mut mem, &[vec![], vec![], vec![], vec!["PAPA"], vec![]]);
        let hit = run(&mem, "PAPA").ok_or("PAPA should resolve after empty buckets")?;
        assert_eq!(hit, addrs[0]);
        Ok(())
    }

    #[test]
    fn returns_first_match_when_duplicates_exist() -> Result<(), String> {
        // Two classes happen to share the name "PAPA" across buckets;
        // we return whichever the walker hits first (deterministic
        // bucket-then-chain order).
        let mut mem = FakeMem::default();
        let addrs = build_image(&mut mem, &[vec!["PAPA"], vec!["PAPA"]]);
        let hit = run(&mem, "PAPA").ok_or("at least one PAPA must match")?;
        assert_eq!(hit, addrs[0]);
        Ok(())
    }
}
