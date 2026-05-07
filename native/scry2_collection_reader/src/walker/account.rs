//! Read MTGA's account-identity record from memory.
//!
//! Chain (verified spike 22, MTGA build Fri Apr 11 17:22:20 2025; see
//! `mtga-duress/experiments/spikes/spike22_papa_managers/FINDING.md`):
//!
//! ```text
//! PAPA._instance                                        (resolved upstream)
//!   .<AccountClient>k__BackingField           -> WizardsAccountsClient
//!     .<AccountInformation>k__BackingField    -> AccountInformation
//!       .DisplayName                          : MonoString * (e.g. "Shawn McCool#91813")
//!       .ExternalID                           : MonoString * (Wizards UUID)
//! ```
//!
//! Field names are resolved via [`super::field::find_field_by_name`];
//! offsets in the FINDING are diagnostic, not constants. The walker
//! survives field-position shifts between MTGA builds — only renames
//! break it.
//!
//! ## Privacy / security posture
//!
//! `AccountInformation` carries fields the walker deliberately
//! **does not read**:
//!
//! - `AccessToken` (offset 0x0030, MonoString) — bearer JWT.
//! - `Email` (offset 0x0038, MonoString) — PII.
//! - `Password` (offset 0x0048, MonoString — usually NULL).
//! - `Credentials` (offset 0x0058) — login provider info.
//!
//! Reading these would leak credentials into our process memory,
//! the snapshot store, and any open-source artifacts. The walker
//! only ever resolves the two fields it explicitly names: `DisplayName`
//! and `ExternalID`. If a future need adds more, the new field name
//! must be added below — there is no "read everything" pathway.
//!
//! ## Tear-down behaviour
//!
//! The chain is **stable across match boundaries** (unlike Chain 1's
//! `MatchManager.LocalPlayerInfo`). Pre-login,
//! `PAPA._instance.AccountClient` may be reachable but
//! `AccountInformation` is null — the walker returns `None` in that
//! case rather than erroring.

use super::instance_field;
use super::mono::MonoOffsets;
use super::object;

/// Cap on the per-string read. MTGA `DisplayName` is "ProperName#NNNNN"
/// — well under 64 chars in practice; UUID-shaped fields are 36 chars.
/// 128 leaves headroom while bounding torn-read damage.
const MAX_STRING_CHARS: usize = 128;

const PAPA_ANCHOR_FIELD: &str = "<AccountClient>k__BackingField";
const ACCOUNT_INFO_FIELD: &str = "<AccountInformation>k__BackingField";

const DISPLAY_NAME_FIELD: &str = "DisplayName";
const EXTERNAL_ID_FIELD: &str = "ExternalID";

/// Snapshot of the player's account identity as MTGA reports it
/// in-process.
///
/// Both fields are `Option<String>` because either may be unset at
/// the point of the read (e.g. the field exists but `MonoString *`
/// is null). The whole struct is `None` (returned by
/// [`from_papa_singleton`]) when the chain itself is unreachable —
/// most commonly pre-login.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AccountIdentity {
    /// `AccountInformation.DisplayName` — the player-facing screen
    /// name with the MTGA discriminator suffix (e.g.
    /// `"Shawn McCool#91813"`). The bare-name component (without
    /// `#NNNNN`) is also captured by `Scry2.Players` from `LoginV3`
    /// log events; only the discriminator-bearing form lives in
    /// memory.
    pub display_name: Option<String>,

    /// `AccountInformation.ExternalID` — the canonical Wizards player
    /// UUID. Cross-validates against `Scry2.Players.mtga_user_id`
    /// (which is sourced from the same identity field surfaced via
    /// `LoginV3`).
    pub external_id: Option<String>,
}

/// Walk PAPA → AccountClient → AccountInformation → identity fields.
///
/// Returns `None` when the chain is unreachable at any hop (anchor
/// null, AccountInformation null). A successful return guarantees
/// neither `Email` nor `AccessToken` was touched — see module docs.
pub fn from_papa_singleton<F>(
    offsets: &MonoOffsets,
    papa_singleton_addr: u64,
    papa_class_bytes: &[u8],
    read_mem: F,
) -> Option<AccountIdentity>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    // Hop 1: PAPA._instance → WizardsAccountsClient
    let client_addr = object::read_instance_pointer(
        offsets,
        papa_class_bytes,
        papa_singleton_addr,
        PAPA_ANCHOR_FIELD,
        &read_mem,
    )?;
    let client_class_bytes = object::read_runtime_class_bytes(client_addr, &read_mem)?;

    // Hop 2: WizardsAccountsClient.AccountInformation → AccountInformation
    let info_addr = object::read_instance_pointer(
        offsets,
        &client_class_bytes,
        client_addr,
        ACCOUNT_INFO_FIELD,
        &read_mem,
    )?;
    let info_class_bytes = object::read_runtime_class_bytes(info_addr, &read_mem)?;

    // Read only the two whitelisted string fields.
    let display_name = instance_field::read_instance_string(
        offsets,
        &info_class_bytes,
        info_addr,
        DISPLAY_NAME_FIELD,
        MAX_STRING_CHARS,
        &read_mem,
    );
    let external_id = instance_field::read_instance_string(
        offsets,
        &info_class_bytes,
        info_addr,
        EXTERNAL_ID_FIELD,
        MAX_STRING_CHARS,
        &read_mem,
    );

    Some(AccountIdentity {
        display_name,
        external_id,
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

    struct AddrPlan;

    impl AddrPlan {
        const PAPA_OBJECT: u64 = 0x0100_0000;
        const PAPA_CLASS_FIELDS: u64 = 0x0110_0000;

        const CLIENT_OBJECT: u64 = 0x0500_0000;
        const CLIENT_VTABLE: u64 = 0x0510_0000;
        const CLIENT_CLASS: u64 = 0x0520_0000;
        const CLIENT_CLASS_FIELDS: u64 = 0x0530_0000;

        const INFO_OBJECT: u64 = 0x0900_0000;
        const INFO_VTABLE: u64 = 0x0910_0000;
        const INFO_CLASS: u64 = 0x0920_0000;
        const INFO_CLASS_FIELDS: u64 = 0x0930_0000;

        const DISPLAY_NAME_STRING: u64 = 0x0d00_0000;
        const EXTERNAL_ID_STRING: u64 = 0x0d10_0000;
    }

    /// Build PAPA → AccountClient → AccountInformation chain.
    /// `display_name_ptr` / `external_id_ptr` of `0` means null pointer
    /// (field present, value empty); `None` means skip the field
    /// entirely (omit from class definition — covers "field renamed").
    fn build_chain(
        display_name: Option<&str>,
        external_id: Option<&str>,
        info_addr: u64,
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
        stamp_ptr(&mut papa_payload, papa_anchor_offset, AddrPlan::CLIENT_OBJECT);
        mem.add(AddrPlan::PAPA_OBJECT, papa_payload);

        // WizardsAccountsClient — AccountInformation @ +0x10.
        let info_field_offset = 0x10i32;
        let client_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::CLIENT_CLASS_FIELDS,
            &[(ACCOUNT_INFO_FIELD, info_field_offset)],
        );
        install_class_at(
            &mut mem,
            AddrPlan::CLIENT_CLASS,
            AddrPlan::CLIENT_VTABLE,
            client_class_bytes,
        );
        let mut client_payload = vec![0u8; 0x40];
        stamp_ptr(&mut client_payload, 0, AddrPlan::CLIENT_VTABLE);
        stamp_ptr(&mut client_payload, info_field_offset, info_addr);
        mem.add(AddrPlan::CLIENT_OBJECT, client_payload);

        if info_addr != 0 {
            // AccountInformation — DisplayName @ +0x10, ExternalID @ +0x18.
            let display_name_offset = 0x10i32;
            let external_id_offset = 0x18i32;
            let info_class_bytes = install_class_fields(
                &mut mem,
                AddrPlan::INFO_CLASS_FIELDS,
                &[
                    (DISPLAY_NAME_FIELD, display_name_offset),
                    (EXTERNAL_ID_FIELD, external_id_offset),
                ],
            );
            install_class_at(
                &mut mem,
                AddrPlan::INFO_CLASS,
                AddrPlan::INFO_VTABLE,
                info_class_bytes,
            );

            let mut info_payload = vec![0u8; 0x80];
            stamp_ptr(&mut info_payload, 0, AddrPlan::INFO_VTABLE);
            if let Some(name) = display_name {
                install_mono_string(&mut mem, AddrPlan::DISPLAY_NAME_STRING, name);
                stamp_ptr(
                    &mut info_payload,
                    display_name_offset,
                    AddrPlan::DISPLAY_NAME_STRING,
                );
            }
            if let Some(id) = external_id {
                install_mono_string(&mut mem, AddrPlan::EXTERNAL_ID_STRING, id);
                stamp_ptr(
                    &mut info_payload,
                    external_id_offset,
                    AddrPlan::EXTERNAL_ID_STRING,
                );
            }
            mem.add(info_addr, info_payload);
        }

        (mem, offsets, AddrPlan::PAPA_OBJECT, papa_class_bytes)
    }

    #[test]
    fn reads_display_name_and_external_id() {
        let (mem, offsets, papa_addr, papa_class_bytes) = build_chain(
            Some("Shawn McCool#91813"),
            Some("e1d8c4f0-1234-5678-9abc-def012345678"),
            AddrPlan::INFO_OBJECT,
        );

        let identity =
            from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| mem.read(a, l))
                .expect("chain should resolve");

        assert_eq!(identity.display_name.as_deref(), Some("Shawn McCool#91813"));
        assert_eq!(
            identity.external_id.as_deref(),
            Some("e1d8c4f0-1234-5678-9abc-def012345678")
        );
    }

    #[test]
    fn returns_none_when_account_client_pointer_is_null() {
        // Build a PAPA whose <AccountClient>k__BackingField slot is 0.
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let papa_anchor_offset = 0x10i32;
        let papa_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::PAPA_CLASS_FIELDS,
            &[(PAPA_ANCHOR_FIELD, papa_anchor_offset)],
        );
        let papa_payload = vec![0u8; 0x40]; // anchor slot stays 0.
        mem.add(AddrPlan::PAPA_OBJECT, papa_payload);

        let identity = from_papa_singleton(
            &offsets,
            AddrPlan::PAPA_OBJECT,
            &papa_class_bytes,
            |a, l| mem.read(a, l),
        );
        assert!(identity.is_none(), "pre-login chain should resolve to None");
    }

    #[test]
    fn returns_none_when_account_information_pointer_is_null() {
        // PAPA + AccountClient resolve, but AccountInformation slot is 0.
        let (mem, offsets, papa_addr, papa_class_bytes) = build_chain(None, None, 0);

        let identity =
            from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| mem.read(a, l));

        assert!(
            identity.is_none(),
            "AccountInformation null should return None"
        );
    }

    #[test]
    fn handles_partial_fields_gracefully() {
        // DisplayName populated; ExternalID null.
        let (mem, offsets, papa_addr, papa_class_bytes) =
            build_chain(Some("Solo Player#00001"), None, AddrPlan::INFO_OBJECT);

        let identity =
            from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| mem.read(a, l))
                .expect("chain should resolve");

        assert_eq!(identity.display_name.as_deref(), Some("Solo Player#00001"));
        assert!(identity.external_id.is_none());
    }
}

