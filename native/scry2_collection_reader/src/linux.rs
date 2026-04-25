//! Linux implementation: process_vm_readv + /proc parsing.

use std::fs;
use std::io;

use libc::{iovec, process_vm_readv};

use crate::{MapEntry, PlatformError};

fn io_err_to_platform(err: &io::Error) -> PlatformError {
    use io::ErrorKind::*;
    match err.kind() {
        NotFound => PlatformError::NoProcess,
        PermissionDenied => PlatformError::PermissionDenied,
        _ => PlatformError::IoError,
    }
}

pub fn read_bytes(pid: i32, addr: u64, size: usize) -> Result<Vec<u8>, PlatformError> {
    if size == 0 {
        return Ok(Vec::new());
    }

    let mut buf = vec![0u8; size];

    let local = iovec {
        iov_base: buf.as_mut_ptr() as *mut libc::c_void,
        iov_len: size,
    };
    let remote = iovec {
        iov_base: addr as *mut libc::c_void,
        iov_len: size,
    };

    // SAFETY: local/remote each point to one valid iovec; iov_base is a
    // writable buffer owned by `buf` (local) or an address in the remote
    // address space (remote). The syscall copies bytes into `buf` and
    // reports any access failure via errno.
    let n = unsafe { process_vm_readv(pid, &local, 1, &remote, 1, 0) };

    if n < 0 {
        let err = io::Error::last_os_error();
        return Err(match err.raw_os_error() {
            Some(libc::ESRCH) => PlatformError::NoProcess,
            Some(libc::EPERM) => PlatformError::PermissionDenied,
            Some(libc::EFAULT) | Some(libc::ENOMEM) => PlatformError::Unmapped,
            _ => PlatformError::IoError,
        });
    }

    // Short read — the remote region is only partially mapped.
    if (n as usize) < size {
        return Err(PlatformError::Unmapped);
    }

    Ok(buf)
}

pub fn list_maps(pid: i32) -> Result<Vec<MapEntry>, PlatformError> {
    let path = format!("/proc/{}/maps", pid);
    let contents = fs::read_to_string(&path).map_err(|e| io_err_to_platform(&e))?;

    Ok(contents.lines().filter_map(parse_map_line).collect())
}

fn parse_map_line(line: &str) -> Option<MapEntry> {
    // Each /proc/<pid>/maps line has 5 or 6 whitespace-separated columns:
    //   start-end perms offset dev inode [pathname]
    let mut iter = line.split_whitespace();
    let range = iter.next()?;
    let perms = iter.next()?;
    let _offset = iter.next()?;
    let _dev = iter.next()?;
    let _inode = iter.next()?;

    // Anything after the inode is the pathname; re-join so paths
    // containing spaces survive (e.g. Wine-style Windows paths).
    let path_parts: Vec<&str> = iter.collect();
    let path = if path_parts.is_empty() {
        None
    } else {
        Some(path_parts.join(" "))
    };

    let (start_hex, end_hex) = range.split_once('-')?;
    let start = u64::from_str_radix(start_hex, 16).ok()?;
    let end = u64::from_str_radix(end_hex, 16).ok()?;

    Some((start, end, perms.to_string(), path))
}

pub fn list_processes() -> Result<Vec<(u32, String, String)>, PlatformError> {
    let entries = fs::read_dir("/proc").map_err(|e| io_err_to_platform(&e))?;

    let mut procs = Vec::new();
    for entry_res in entries {
        let entry = match entry_res {
            Ok(e) => e,
            Err(_) => continue,
        };

        let name = entry.file_name();
        let name_str = name.to_string_lossy();

        if !name_str.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }

        let pid: u32 = match name_str.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };

        if let Some(info) = read_process_info(pid) {
            procs.push(info);
        }
    }

    Ok(procs)
}

fn read_process_info(pid: u32) -> Option<(u32, String, String)> {
    // /proc/<pid>/comm is the kernel-truncated name (≤ 15 chars),
    // newline-terminated.
    let comm_path = format!("/proc/{}/comm", pid);
    let name = fs::read_to_string(&comm_path).ok()?.trim_end().to_string();

    // /proc/<pid>/cmdline uses NUL between argv entries and a trailing
    // NUL. Replace with spaces for human-readable inspection; trim
    // trailing whitespace so equality comparisons behave.
    let cmdline_path = format!("/proc/{}/cmdline", pid);
    let cmdline_bytes = fs::read(&cmdline_path).ok()?;
    let cmdline = String::from_utf8_lossy(&cmdline_bytes)
        .replace('\0', " ")
        .trim_end()
        .to_string();

    Some((pid, name, cmdline))
}
