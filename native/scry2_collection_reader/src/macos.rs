//! macOS implementation — stub until task_for_pid +
//! mach_vm_read_overwrite bindings land (ADR 034).

use crate::{MapEntry, PlatformError};

pub fn read_bytes(_pid: i32, _addr: u64, _size: usize) -> Result<Vec<u8>, PlatformError> {
    Err(PlatformError::NotImplemented)
}

pub fn list_maps(_pid: i32) -> Result<Vec<MapEntry>, PlatformError> {
    Err(PlatformError::NotImplemented)
}

pub fn list_processes() -> Result<Vec<(u32, String, String)>, PlatformError> {
    Err(PlatformError::NotImplemented)
}
