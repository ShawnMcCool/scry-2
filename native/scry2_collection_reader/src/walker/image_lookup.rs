//! Locate a `MonoImage *` by walking `MonoDomain.domain_assemblies`.
//!
//! `domain_assemblies` is a `GSList` of `MonoAssembly *` — every
//! managed assembly the runtime has loaded into the root domain.
//! Each `MonoAssembly` carries an embedded `MonoAssemblyName` whose
//! first field (`name`, a `const char *`) is the assembly's short
//! name (e.g. `"Core"`, `"Assembly-CSharp"`, `"SharedClientCore"`).
//!
//! For the MTGA collection walk, we navigate from `mono_get_root_domain`
//! to the `MonoImage *` of `Core.dll` (where the `PAPA` class lives),
//! then later from there to `Assembly-CSharp.dll` for inventory types.
//!
//! The `find_by_assembly_name` function takes a remote `MonoDomain *`
//! and a `read_mem` closure (so the same code can run against a live
//! process via `process_vm_readv` or against a `FakeMem` stub in
//! tests). On a successful match it returns the `MonoImage *` for the
//! first assembly whose short name equals `target_name`.

use super::mono::{self, MonoOffsets};

/// Maximum bytes to read from an assembly-name C string. MTGA's
/// assembly short names are uniformly small (longest expected:
/// `"SharedClientCore"` at 16 chars). 256 leaves comfortable headroom
/// without paying for unbounded reads on a malformed pointer.
pub const MAX_NAME_LEN: usize = 256;

/// Hard cap on how many `GSList` nodes the walker will dereference.
/// MTGA's root domain typically holds ~30 assemblies; a runaway loop
/// on a corrupted `next` pointer must be bounded so the NIF returns
/// in finite time. 1024 is far above any realistic assembly count.
pub const MAX_ASSEMBLIES: usize = 1024;

/// Walk `domain->domain_assemblies` and return the `MonoImage *` for
/// the first assembly whose short name matches `target_name`.
///
/// Returns `None` when:
/// - The `domain_assemblies` head pointer cannot be read (read miss
///   on the domain itself).
/// - The list is empty (head == 0).
/// - No assembly matches `target_name` within `MAX_ASSEMBLIES` nodes.
///
/// A read miss on an individual node — or on the name string of a
/// candidate assembly — is treated as a non-match for *that* entry;
/// iteration continues. This mirrors `field::find_by_name`'s posture.
///
/// `read_mem(addr, len)` fetches `len` bytes from the target process
/// at remote address `addr`. In tests this is a `FakeMem`-style stub.
pub fn find_by_assembly_name<F>(
    offsets: &MonoOffsets,
    domain_addr: u64,
    target_name: &str,
    read_mem: F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let head = read_domain_assemblies_head(offsets, domain_addr, &read_mem)?;
    if head == 0 {
        return None;
    }

    let target_bytes = target_name.as_bytes();
    let mut node = head;
    for _ in 0..MAX_ASSEMBLIES {
        let node_buf = read_mem(node, gslist_node_size(offsets))?;
        let assembly_ptr = mono::gslist_data_ptr(offsets, &node_buf, 0)?;
        let next = mono::gslist_next_ptr(offsets, &node_buf, 0)?;

        if assembly_ptr != 0
            && assembly_matches(offsets, assembly_ptr, target_bytes, &read_mem).unwrap_or(false)
        {
            return read_assembly_image(offsets, assembly_ptr, &read_mem);
        }

        if next == 0 {
            return None;
        }
        node = next;
    }
    None
}

/// Read `MonoDomain.domain_assemblies` (a single `u64`) from the
/// target process. We fetch only the 8-byte slot rather than the
/// whole `MonoDomain`, which keeps the read footprint minimal.
fn read_domain_assemblies_head<F>(
    offsets: &MonoOffsets,
    domain_addr: u64,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let slot_addr = domain_addr.checked_add(offsets.domain_assemblies as u64)?;
    let buf = read_mem(slot_addr, 8)?;
    mono::read_ptr(&buf, 0, 0)
}

/// Number of bytes spanned by one `GSList` node (`data` + `next`).
fn gslist_node_size(offsets: &MonoOffsets) -> usize {
    offsets.gslist_next + 8
}

/// Test whether the assembly at `assembly_ptr` has a short name
/// equal to `target_bytes` (no trailing NUL on `target_bytes`).
/// Returns `Some(true)` on match, `Some(false)` on definite mismatch,
/// `None` on a read failure that prevents the comparison.
fn assembly_matches<F>(
    offsets: &MonoOffsets,
    assembly_ptr: u64,
    target_bytes: &[u8],
    read_mem: &F,
) -> Option<bool>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let name_slot = assembly_ptr.checked_add(offsets.assembly_aname_name as u64)?;
    let name_ptr_buf = read_mem(name_slot, 8)?;
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

/// Read `MonoAssembly.image` (a single `u64`) from the target process.
fn read_assembly_image<F>(offsets: &MonoOffsets, assembly_ptr: u64, read_mem: &F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let slot = assembly_ptr.checked_add(offsets.assembly_image as u64)?;
    let buf = read_mem(slot, 8)?;
    let image = mono::read_ptr(&buf, 0, 0)?;
    if image == 0 {
        None
    } else {
        Some(image)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// FakeMem fixture identical in spirit to the one in `field.rs`
    /// tests — maps remote addresses to byte blocks; reads return up
    /// to `len` bytes from the block that contains `addr`.
    #[derive(Default)]
    struct FakeMem {
        blocks: Vec<(u64, Vec<u8>)>,
    }

    impl FakeMem {
        fn add(&mut self, addr: u64, bytes: Vec<u8>) {
            self.blocks.push((addr, bytes));
        }

        fn read(&self, addr: u64, len: usize) -> Option<Vec<u8>> {
            for (base, data) in &self.blocks {
                if addr >= *base {
                    let off = (addr - *base) as usize;
                    if off < data.len() {
                        let end = off.saturating_add(len).min(data.len());
                        return Some(data[off..end].to_vec());
                    }
                }
            }
            None
        }
    }

    /// Lay out a chain of `n` GSList nodes pointing at MonoAssembly
    /// blocks at deterministic addresses, with the given short
    /// names. Returns the address of the head node.
    fn build_assembly_chain(mem: &mut FakeMem, names: &[&str]) -> u64 {
        let offsets = MonoOffsets::mtga_default();
        let nodes_base: u64 = 0x1_0000_0000;
        let assemblies_base: u64 = 0x2_0000_0000;
        let names_base: u64 = 0x3_0000_0000;
        let images_base: u64 = 0x4_0000_0000;
        let node_size = gslist_node_size(&offsets) as u64;

        for (i, name) in names.iter().enumerate() {
            let node_addr = nodes_base + (i as u64) * node_size;
            let asm_addr = assemblies_base + (i as u64) * 0x100;
            let name_addr = names_base + (i as u64) * 0x100;
            let image_addr = images_base + (i as u64) * 0x10;

            // GSList node — data = assembly *, next = next node or 0.
            let mut node = vec![0u8; node_size as usize];
            node[offsets.gslist_data..offsets.gslist_data + 8]
                .copy_from_slice(&asm_addr.to_le_bytes());
            let next_addr = if i + 1 < names.len() {
                node_addr + node_size
            } else {
                0
            };
            node[offsets.gslist_next..offsets.gslist_next + 8]
                .copy_from_slice(&next_addr.to_le_bytes());
            mem.add(node_addr, node);

            // MonoAssembly — only fields we touch: aname.name (at +0x10)
            // and image (at +0x60).
            let asm_size = offsets.assembly_image + 8;
            let mut asm = vec![0u8; asm_size];
            asm[offsets.assembly_aname_name..offsets.assembly_aname_name + 8]
                .copy_from_slice(&name_addr.to_le_bytes());
            asm[offsets.assembly_image..offsets.assembly_image + 8]
                .copy_from_slice(&image_addr.to_le_bytes());
            mem.add(asm_addr, asm);

            // Name string, NUL-terminated.
            let mut name_bytes = name.as_bytes().to_vec();
            name_bytes.push(0);
            mem.add(name_addr, name_bytes);
        }
        nodes_base
    }

    /// Build the MonoDomain block holding the head pointer at offset
    /// `domain_assemblies` (0xa0). Returns the domain's remote
    /// address.
    fn build_domain(mem: &mut FakeMem, head_ptr: u64) -> u64 {
        let offsets = MonoOffsets::mtga_default();
        let domain_addr: u64 = 0x5_0000_0000;
        let mut domain = vec![0u8; offsets.domain_assemblies + 8];
        domain[offsets.domain_assemblies..offsets.domain_assemblies + 8]
            .copy_from_slice(&head_ptr.to_le_bytes());
        mem.add(domain_addr, domain);
        domain_addr
    }

    fn run(mem: &FakeMem, domain_addr: u64, target: &str) -> Option<u64> {
        let offsets = MonoOffsets::mtga_default();
        find_by_assembly_name(&offsets, domain_addr, target, |addr, len| {
            mem.read(addr, len)
        })
    }

    #[test]
    fn finds_first_assembly_when_head_matches() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let head = build_assembly_chain(&mut mem, &["Core", "Assembly-CSharp"]);
        let domain = build_domain(&mut mem, head);

        let image = run(&mem, domain, "Core").ok_or("Core should resolve")?;
        assert_eq!(image, 0x4_0000_0000);
        Ok(())
    }

    #[test]
    fn finds_assembly_in_middle_of_chain() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let head =
            build_assembly_chain(&mut mem, &["mscorlib", "System", "Assembly-CSharp", "Core"]);
        let domain = build_domain(&mut mem, head);

        let image = run(&mem, domain, "Assembly-CSharp")
            .ok_or("Assembly-CSharp should resolve mid-chain")?;
        // assemblies_base + 2 * 0x100 → image at images_base + 2 * 0x10
        assert_eq!(image, 0x4_0000_0000 + 2 * 0x10);
        Ok(())
    }

    #[test]
    fn finds_last_assembly_in_chain() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let head = build_assembly_chain(&mut mem, &["A", "B", "SharedClientCore"]);
        let domain = build_domain(&mut mem, head);

        let image = run(&mem, domain, "SharedClientCore")
            .ok_or("SharedClientCore should resolve at tail")?;
        assert_eq!(image, 0x4_0000_0000 + 2 * 0x10);
        Ok(())
    }

    #[test]
    fn returns_none_when_no_assembly_matches() {
        let mut mem = FakeMem::default();
        let head = build_assembly_chain(&mut mem, &["alpha", "beta", "gamma"]);
        let domain = build_domain(&mut mem, head);

        assert_eq!(run(&mem, domain, "Core"), None);
    }

    #[test]
    fn returns_none_when_domain_assemblies_head_is_zero() {
        let mut mem = FakeMem::default();
        let domain = build_domain(&mut mem, 0);
        assert_eq!(run(&mem, domain, "Core"), None);
    }

    #[test]
    fn returns_none_when_domain_address_unreadable() {
        let mem = FakeMem::default();
        // No domain block in mem → read of the +0xa0 slot misses.
        assert_eq!(run(&mem, 0xdead_beef_0000, "Core"), None);
    }

    #[test]
    fn name_match_is_exact_no_prefix_match() -> Result<(), String> {
        let mut mem = FakeMem::default();
        // Looking for "Core" should NOT match the assembly named
        // "CoreLib" — the comparison is bytewise, not prefix-based.
        let head = build_assembly_chain(&mut mem, &["CoreLib", "Core"]);
        let domain = build_domain(&mut mem, head);

        let image = run(&mem, domain, "Core").ok_or("exact 'Core' should still match")?;
        assert_eq!(image, 0x4_0000_0000 + 0x10);
        Ok(())
    }

    #[test]
    fn skips_assembly_with_unreadable_name_pointer() -> Result<(), String> {
        // First assembly's name pointer is unmapped → walker
        // skips it and finds the second.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        let nodes_base: u64 = 0x1_0000_0000;
        let node_size = gslist_node_size(&offsets) as u64;
        let asm0_addr: u64 = 0x2_0000_0000;
        let asm1_addr: u64 = 0x2_0000_1000;
        let bad_name_ptr: u64 = 0x9999_9999_9999_9999;
        let good_name_ptr: u64 = 0x3_0000_0000;
        let image_ptr: u64 = 0x4_0000_0000;

        // Node 0 → asm0 (bad name)
        let mut node0 = vec![0u8; node_size as usize];
        node0[offsets.gslist_data..offsets.gslist_data + 8]
            .copy_from_slice(&asm0_addr.to_le_bytes());
        let next0 = nodes_base + node_size;
        node0[offsets.gslist_next..offsets.gslist_next + 8].copy_from_slice(&next0.to_le_bytes());
        mem.add(nodes_base, node0);

        // Node 1 → asm1 (good name "Core")
        let mut node1 = vec![0u8; node_size as usize];
        node1[offsets.gslist_data..offsets.gslist_data + 8]
            .copy_from_slice(&asm1_addr.to_le_bytes());
        // next = 0 → end of list
        mem.add(nodes_base + node_size, node1);

        // asm0 — name points to unmapped memory
        let asm_size = offsets.assembly_image + 8;
        let mut asm0 = vec![0u8; asm_size];
        asm0[offsets.assembly_aname_name..offsets.assembly_aname_name + 8]
            .copy_from_slice(&bad_name_ptr.to_le_bytes());
        mem.add(asm0_addr, asm0);

        // asm1 — name "Core", image set
        let mut asm1 = vec![0u8; asm_size];
        asm1[offsets.assembly_aname_name..offsets.assembly_aname_name + 8]
            .copy_from_slice(&good_name_ptr.to_le_bytes());
        asm1[offsets.assembly_image..offsets.assembly_image + 8]
            .copy_from_slice(&image_ptr.to_le_bytes());
        mem.add(asm1_addr, asm1);

        let mut good_name = b"Core".to_vec();
        good_name.push(0);
        mem.add(good_name_ptr, good_name);

        let domain = build_domain(&mut mem, nodes_base);
        let image = run(&mem, domain, "Core").ok_or("second entry should match")?;
        assert_eq!(image, image_ptr);
        Ok(())
    }

    #[test]
    fn returns_none_when_image_pointer_is_zero() {
        // An assembly that matches the name but whose image pointer
        // is null (still loading? unloaded?) yields None — the
        // walker treats no-image as no-match for now.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        let nodes_base: u64 = 0x1_0000_0000;
        let node_size = gslist_node_size(&offsets) as u64;
        let asm_addr: u64 = 0x2_0000_0000;
        let name_ptr: u64 = 0x3_0000_0000;

        let mut node = vec![0u8; node_size as usize];
        node[offsets.gslist_data..offsets.gslist_data + 8].copy_from_slice(&asm_addr.to_le_bytes());
        // next = 0
        mem.add(nodes_base, node);

        let asm_size = offsets.assembly_image + 8;
        let mut asm = vec![0u8; asm_size];
        asm[offsets.assembly_aname_name..offsets.assembly_aname_name + 8]
            .copy_from_slice(&name_ptr.to_le_bytes());
        // image stays 0.
        mem.add(asm_addr, asm);

        let mut nm = b"Core".to_vec();
        nm.push(0);
        mem.add(name_ptr, nm);

        let domain = build_domain(&mut mem, nodes_base);
        assert_eq!(run(&mem, domain, "Core"), None);
    }

    #[test]
    fn caps_iteration_at_max_assemblies_on_cycle() {
        // Construct a one-node ring (next points back to itself) with a
        // non-matching name — the walker must terminate via the
        // MAX_ASSEMBLIES cap rather than spin forever.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        let nodes_base: u64 = 0x1_0000_0000;
        let asm_addr: u64 = 0x2_0000_0000;
        let name_ptr: u64 = 0x3_0000_0000;
        let node_size = gslist_node_size(&offsets) as u64;

        let mut node = vec![0u8; node_size as usize];
        node[offsets.gslist_data..offsets.gslist_data + 8].copy_from_slice(&asm_addr.to_le_bytes());
        // next = self → cycle
        node[offsets.gslist_next..offsets.gslist_next + 8]
            .copy_from_slice(&nodes_base.to_le_bytes());
        mem.add(nodes_base, node);

        let asm_size = offsets.assembly_image + 8;
        let mut asm = vec![0u8; asm_size];
        asm[offsets.assembly_aname_name..offsets.assembly_aname_name + 8]
            .copy_from_slice(&name_ptr.to_le_bytes());
        mem.add(asm_addr, asm);

        let mut nm = b"NotMatching".to_vec();
        nm.push(0);
        mem.add(name_ptr, nm);

        let domain = build_domain(&mut mem, nodes_base);
        assert_eq!(run(&mem, domain, "Core"), None);
    }

    #[test]
    fn skips_node_with_zero_assembly_pointer() {
        // GSList node whose `data` is 0 (unusual but possible during
        // teardown) — walker should skip and move to next.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        let nodes_base: u64 = 0x1_0000_0000;
        let node_size = gslist_node_size(&offsets) as u64;
        let asm1_addr: u64 = 0x2_0000_1000;
        let name_ptr: u64 = 0x3_0000_0000;
        let image_ptr: u64 = 0x4_0000_0000;

        // Node 0 — data = 0, next → node 1
        let mut node0 = vec![0u8; node_size as usize];
        let next0 = nodes_base + node_size;
        node0[offsets.gslist_next..offsets.gslist_next + 8].copy_from_slice(&next0.to_le_bytes());
        mem.add(nodes_base, node0);

        // Node 1 — data → asm1, next = 0
        let mut node1 = vec![0u8; node_size as usize];
        node1[offsets.gslist_data..offsets.gslist_data + 8]
            .copy_from_slice(&asm1_addr.to_le_bytes());
        mem.add(nodes_base + node_size, node1);

        let asm_size = offsets.assembly_image + 8;
        let mut asm = vec![0u8; asm_size];
        asm[offsets.assembly_aname_name..offsets.assembly_aname_name + 8]
            .copy_from_slice(&name_ptr.to_le_bytes());
        asm[offsets.assembly_image..offsets.assembly_image + 8]
            .copy_from_slice(&image_ptr.to_le_bytes());
        mem.add(asm1_addr, asm);

        let mut nm = b"Core".to_vec();
        nm.push(0);
        mem.add(name_ptr, nm);

        let domain = build_domain(&mut mem, nodes_base);
        assert_eq!(run(&mem, domain, "Core"), Some(image_ptr));
    }
}
