//! Windows implementation — stub until OpenProcess / ReadProcessMemory
//! / VirtualQueryEx / CreateToolhelp32Snapshot bindings land (ADR 034).

use crate::PlatformError;

pub fn read_bytes(_pid: i32, _addr: u64, _size: usize) -> Result<Vec<u8>, PlatformError> {
    Err(PlatformError::NotImplemented)
}

pub fn list_maps(_pid: i32) -> Result<Vec<(u64, u64, String, Option<String>)>, PlatformError> {
    Err(PlatformError::NotImplemented)
}

pub fn list_processes() -> Result<Vec<(u32, String, String)>, PlatformError> {
    Err(PlatformError::NotImplemented)
}
