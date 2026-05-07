//! Read MTGA's server-environment record from memory.
//!
//! Chain (verified spike 23, MTGA build Fri Apr 11 17:22:20 2025; see
//! `mtga-duress/experiments/spikes/spike23_environment_anchor/FINDING.md`):
//!
//! ```text
//! PAPA._instance                                      (resolved upstream)
//!   .<FdConnectionManager>k__BackingField  -> FrontDoorConnectionManager
//!     ._currentEnvironment                  -> EnvironmentDescription
//!       .name                               : MonoString * (e.g. "Prod")
//!       .fdHost                             : MonoString * (e.g.
//!         "frontdoor-mtga-production-2026-58-30-2.w2.mtgarena.com")
//!       .fdPort                             : i32  (e.g. 30010)
//!       .HostPlatform                       : i32  (1 = Steam observed)
//! ```
//!
//! Field names are resolved via [`super::field::find_field_by_name`];
//! offsets in the FINDING are diagnostic, not constants. The walker
//! survives field-position shifts between MTGA builds — only renames
//! break it.
//!
//! ## Privacy / security posture
//!
//! `EnvironmentDescription` co-locates **OAuth client secrets** in the
//! same struct as the public service URIs:
//!
//! - `accountSystemSecret` (offset 0x0038, MonoString)
//! - `epicWASClientSecret` (offset 0x0048, MonoString)
//! - `steamClientSecret`   (offset 0x0058, MonoString)
//!
//! These are production secrets the MTGA client uses to authenticate
//! against the Wizards account system. The walker deliberately reads
//! ONLY the four fields named below — `name`, `fdHost`, `fdPort`,
//! `HostPlatform`. There is no "read everything" pathway. If a future
//! caller adds another field, that field must be explicitly named
//! here and reviewed against the secret list above.
//!
//! ## Tear-down behaviour
//!
//! The chain is **stable across match boundaries** and across login
//! state. `_currentEnvironment` is populated very early in MTGA
//! startup; the walker is unlikely to ever return `None` against a
//! running MTGA process unless the FrontDoorConnectionManager itself
//! is null (pre-bootstrap).

use super::instance_field;
use super::mono::MonoOffsets;
use super::object;

/// Cap on per-string read. `name` is short ("Prod"); `fdHost` is the
/// front-door FQDN — under 80 chars in practice. 128 leaves headroom
/// while bounding torn-read damage.
const MAX_STRING_CHARS: usize = 128;

const PAPA_ANCHOR_FIELD: &str = "<FdConnectionManager>k__BackingField";
const ENVIRONMENT_FIELD: &str = "_currentEnvironment";

const NAME_FIELD: &str = "name";
const FD_HOST_FIELD: &str = "fdHost";
const FD_PORT_FIELD: &str = "fdPort";
const HOST_PLATFORM_FIELD: &str = "HostPlatform";

/// Snapshot of the MTGA server environment the client is talking to.
///
/// All fields are `Option<_>` because either the underlying string can
/// be null or the i32 field can be unresolved on a build with renamed
/// fields. The whole struct is `None` (returned by
/// [`from_papa_singleton`]) when the chain itself is unreachable.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EnvironmentInfo {
    /// `EnvironmentDescription.name` — human-readable environment
    /// label. Observed: `"Prod"`. Other values (PTR / Stage / QA)
    /// undocumented.
    pub name: Option<String>,

    /// `EnvironmentDescription.fdHost` — front-door (game server)
    /// FQDN. Observed format:
    /// `"frontdoor-mtga-<env>-<build-version>.<region>.mtgarena.com"`.
    /// The build-version segment changes with every MTGA release;
    /// callers can parse it back out for a human-readable build id.
    pub fd_host: Option<String>,

    /// `EnvironmentDescription.fdPort` — front-door TCP port.
    /// Observed: `30010`.
    pub fd_port: Option<i32>,

    /// `EnvironmentDescription.HostPlatform` — i32 enum identifying
    /// the host platform the MTGA client thinks it's running under.
    /// Observed: `1` on Steam. Other values undocumented.
    pub host_platform: Option<i32>,
}

/// Walk PAPA → FdConnectionManager → _currentEnvironment → public
/// fields.
///
/// Returns `None` when the chain is unreachable at any hop (anchor
/// null, `_currentEnvironment` null). A successful return guarantees
/// none of `accountSystemSecret`, `epicWASClientSecret`, or
/// `steamClientSecret` was touched — see module docs.
pub fn from_papa_singleton<F>(
    offsets: &MonoOffsets,
    papa_singleton_addr: u64,
    papa_class_bytes: &[u8],
    read_mem: F,
) -> Option<EnvironmentInfo>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    // Hop 1: PAPA._instance → FrontDoorConnectionManager
    let manager_addr = object::read_instance_pointer(
        offsets,
        papa_class_bytes,
        papa_singleton_addr,
        PAPA_ANCHOR_FIELD,
        &read_mem,
    )?;
    let manager_class_bytes = object::read_runtime_class_bytes(manager_addr, &read_mem)?;

    // Hop 2: FrontDoorConnectionManager._currentEnvironment → EnvironmentDescription
    let env_addr = object::read_instance_pointer(
        offsets,
        &manager_class_bytes,
        manager_addr,
        ENVIRONMENT_FIELD,
        &read_mem,
    )?;
    let env_class_bytes = object::read_runtime_class_bytes(env_addr, &read_mem)?;

    // Read only the four whitelisted fields.
    let name = instance_field::read_instance_string(
        offsets,
        &env_class_bytes,
        env_addr,
        NAME_FIELD,
        MAX_STRING_CHARS,
        &read_mem,
    );
    let fd_host = instance_field::read_instance_string(
        offsets,
        &env_class_bytes,
        env_addr,
        FD_HOST_FIELD,
        MAX_STRING_CHARS,
        &read_mem,
    );
    let fd_port = instance_field::read_instance_i32(
        offsets,
        &env_class_bytes,
        env_addr,
        FD_PORT_FIELD,
        &read_mem,
    );
    let host_platform = instance_field::read_instance_i32(
        offsets,
        &env_class_bytes,
        env_addr,
        HOST_PLATFORM_FIELD,
        &read_mem,
    );

    Some(EnvironmentInfo {
        name,
        fd_host,
        fd_port,
        host_platform,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;
    use crate::walker::test_support::{make_class_def, make_field_entry, make_type_block, FakeMem};

    type FieldSpec<'a> = (&'a str, i32);

    fn install_class_fields(
        mem: &mut FakeMem,
        fields_addr: u64,
        fields: &[FieldSpec<'_>],
    ) -> Vec<u8> {
        let names_base = fields_addr + 0x1_0000;
        let types_base = fields_addr + 0x2_0000;
        let mut entry_blob = Vec::with_capacity(fields.len() * MONO_CLASS_FIELD_SIZE);
        for (i, (name, offset)) in fields.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x80;
            let type_ptr = types_base + (i as u64) * 0x20;
            entry_blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, 0, *offset));
            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(name_ptr, name_buf);
            mem.add(type_ptr, make_type_block(0));
        }
        mem.add(fields_addr, entry_blob);
        make_class_def(fields_addr, fields.len() as u32)
    }

    fn install_class_at(
        mem: &mut FakeMem,
        class_addr: u64,
        vtable_addr: u64,
        class_bytes: Vec<u8>,
    ) {
        mem.add(class_addr, class_bytes);
        let mut vt = vec![0u8; 0x10];
        vt[0..8].copy_from_slice(&class_addr.to_le_bytes());
        mem.add(vtable_addr, vt);
    }

    fn install_mono_string(mem: &mut FakeMem, addr: u64, s: &str) {
        let utf16: Vec<u16> = s.encode_utf16().collect();
        let mut hdr = vec![0u8; 0x14];
        hdr[0x10..0x14].copy_from_slice(&(utf16.len() as i32).to_le_bytes());
        mem.add(addr, hdr);
        let mut chars = Vec::with_capacity(utf16.len() * 2);
        for u in &utf16 {
            chars.extend_from_slice(&u.to_le_bytes());
        }
        mem.add(addr + 0x14, chars);
    }

    fn stamp_ptr(payload: &mut [u8], offset: i32, ptr: u64) {
        let off = offset as usize;
        payload[off..off + 8].copy_from_slice(&ptr.to_le_bytes());
    }

    fn stamp_i32(payload: &mut [u8], offset: i32, value: i32) {
        let off = offset as usize;
        payload[off..off + 4].copy_from_slice(&value.to_le_bytes());
    }

    struct AddrPlan;

    impl AddrPlan {
        const PAPA_OBJECT: u64 = 0x0100_0000;
        const PAPA_CLASS_FIELDS: u64 = 0x0110_0000;

        const MGR_OBJECT: u64 = 0x0500_0000;
        const MGR_VTABLE: u64 = 0x0510_0000;
        const MGR_CLASS: u64 = 0x0520_0000;
        const MGR_CLASS_FIELDS: u64 = 0x0530_0000;

        const ENV_OBJECT: u64 = 0x0900_0000;
        const ENV_VTABLE: u64 = 0x0910_0000;
        const ENV_CLASS: u64 = 0x0920_0000;
        const ENV_CLASS_FIELDS: u64 = 0x0930_0000;

        const NAME_STRING: u64 = 0x0d00_0000;
        const FD_HOST_STRING: u64 = 0x0d10_0000;
    }

    /// Build PAPA → FdConnectionManager → _currentEnvironment chain.
    /// Pass `env_addr = 0` to simulate a null `_currentEnvironment`.
    fn build_chain(
        name: Option<&str>,
        fd_host: Option<&str>,
        fd_port: Option<i32>,
        host_platform: Option<i32>,
        env_addr: u64,
    ) -> (FakeMem, MonoOffsets, u64, Vec<u8>) {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        // PAPA — one anchor field.
        let papa_anchor_offset = 0x10i32;
        let papa_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::PAPA_CLASS_FIELDS,
            &[(PAPA_ANCHOR_FIELD, papa_anchor_offset)],
        );
        let mut papa_payload = vec![0u8; 0x40];
        stamp_ptr(&mut papa_payload, papa_anchor_offset, AddrPlan::MGR_OBJECT);
        mem.add(AddrPlan::PAPA_OBJECT, papa_payload);

        // FrontDoorConnectionManager — _currentEnvironment @ +0x10.
        let env_field_offset = 0x10i32;
        let mgr_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::MGR_CLASS_FIELDS,
            &[(ENVIRONMENT_FIELD, env_field_offset)],
        );
        install_class_at(
            &mut mem,
            AddrPlan::MGR_CLASS,
            AddrPlan::MGR_VTABLE,
            mgr_class_bytes,
        );
        let mut mgr_payload = vec![0u8; 0x40];
        stamp_ptr(&mut mgr_payload, 0, AddrPlan::MGR_VTABLE);
        stamp_ptr(&mut mgr_payload, env_field_offset, env_addr);
        mem.add(AddrPlan::MGR_OBJECT, mgr_payload);

        if env_addr != 0 {
            // EnvironmentDescription:
            //   name             @ +0x10 (string ptr)
            //   fdHost           @ +0x18 (string ptr)
            //   fdPort           @ +0x40 (i32)
            //   HostPlatform     @ +0x48 (i32)
            let name_offset = 0x10i32;
            let fd_host_offset = 0x18i32;
            let fd_port_offset = 0x40i32;
            let host_platform_offset = 0x48i32;
            let env_class_bytes = install_class_fields(
                &mut mem,
                AddrPlan::ENV_CLASS_FIELDS,
                &[
                    (NAME_FIELD, name_offset),
                    (FD_HOST_FIELD, fd_host_offset),
                    (FD_PORT_FIELD, fd_port_offset),
                    (HOST_PLATFORM_FIELD, host_platform_offset),
                ],
            );
            install_class_at(
                &mut mem,
                AddrPlan::ENV_CLASS,
                AddrPlan::ENV_VTABLE,
                env_class_bytes,
            );

            let mut env_payload = vec![0u8; 0x80];
            stamp_ptr(&mut env_payload, 0, AddrPlan::ENV_VTABLE);
            if let Some(s) = name {
                install_mono_string(&mut mem, AddrPlan::NAME_STRING, s);
                stamp_ptr(&mut env_payload, name_offset, AddrPlan::NAME_STRING);
            }
            if let Some(s) = fd_host {
                install_mono_string(&mut mem, AddrPlan::FD_HOST_STRING, s);
                stamp_ptr(&mut env_payload, fd_host_offset, AddrPlan::FD_HOST_STRING);
            }
            if let Some(v) = fd_port {
                stamp_i32(&mut env_payload, fd_port_offset, v);
            }
            if let Some(v) = host_platform {
                stamp_i32(&mut env_payload, host_platform_offset, v);
            }
            mem.add(env_addr, env_payload);
        }

        (mem, offsets, AddrPlan::PAPA_OBJECT, papa_class_bytes)
    }

    #[test]
    fn reads_name_host_port_and_platform() {
        let (mem, offsets, papa_addr, papa_class_bytes) = build_chain(
            Some("Prod"),
            Some("frontdoor-mtga-production-2026-58-30-2.w2.mtgarena.com"),
            Some(30010),
            Some(1),
            AddrPlan::ENV_OBJECT,
        );

        let env =
            from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| mem.read(a, l))
                .expect("chain should resolve");

        assert_eq!(env.name.as_deref(), Some("Prod"));
        assert_eq!(
            env.fd_host.as_deref(),
            Some("frontdoor-mtga-production-2026-58-30-2.w2.mtgarena.com")
        );
        assert_eq!(env.fd_port, Some(30010));
        assert_eq!(env.host_platform, Some(1));
    }

    #[test]
    fn returns_none_when_fd_connection_manager_pointer_is_null() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let papa_anchor_offset = 0x10i32;
        let papa_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::PAPA_CLASS_FIELDS,
            &[(PAPA_ANCHOR_FIELD, papa_anchor_offset)],
        );
        let papa_payload = vec![0u8; 0x40]; // anchor stays 0
        mem.add(AddrPlan::PAPA_OBJECT, papa_payload);

        assert!(
            from_papa_singleton(&offsets, AddrPlan::PAPA_OBJECT, &papa_class_bytes, |a, l| {
                mem.read(a, l)
            })
            .is_none()
        );
    }

    #[test]
    fn returns_none_when_current_environment_is_null() {
        let (mem, offsets, papa_addr, papa_class_bytes) = build_chain(None, None, None, None, 0);

        assert!(
            from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| mem.read(a, l))
                .is_none()
        );
    }

    #[test]
    fn handles_partial_fields_gracefully() {
        // name + fdHost present; fdPort + HostPlatform not stamped (i32 reads
        // will see zero — that's a legit value distinguishable from "missing"
        // only by domain knowledge, which is the caller's job).
        let (mem, offsets, papa_addr, papa_class_bytes) = build_chain(
            Some("Stage"),
            Some("frontdoor-stage.example.com"),
            None,
            None,
            AddrPlan::ENV_OBJECT,
        );

        let env =
            from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| mem.read(a, l))
                .expect("chain should resolve");

        assert_eq!(env.name.as_deref(), Some("Stage"));
        assert_eq!(env.fd_host.as_deref(), Some("frontdoor-stage.example.com"));
        // Default-stamped i32 reads as 0 (the buffer is zero-initialized).
        assert_eq!(env.fd_port, Some(0));
        assert_eq!(env.host_platform, Some(0));
    }
}
