//! Unpacking of the release archives: `.tar.gz` (ustar and GNU tar, with GNU long names and pax
//! headers) and `.zip` (stored or deflated entries). Only directories and regular files below the
//! one top-level directory `root` are accepted; anything else (links, absolute paths, `..`,
//! entries outside `root`) makes the unpacking fail.

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use flate2::read::{DeflateDecoder, GzDecoder};

/// An entry of an archive
struct Entry {
    /// Path relative to the archive root, `/`-separated; directories end with `/`
    name: String,
    /// The contents of a file, `None` for a directory
    data: Option<Vec<u8>>,
}

/// Checks that `name` is a relative path below `root/` and returns it
fn check_name(name: &[u8], root: &str) -> Result<String, String> {
    let name = String::from_utf8(name.to_vec()).map_err(|_| {
        format!(
            "the archive has an entry whose path is not UTF-8: {:?}",
            String::from_utf8_lossy(name)
        )
    })?;
    let parts: Vec<&str> = name.strip_suffix('/').unwrap_or(&name).split('/').collect();
    if name.contains('\\') || name.contains('\0') || parts.iter().any(|p| p.is_empty() || *p == "." || *p == "..") {
        return Err(format!("the archive has an entry with an invalid path: {name:?}"));
    }
    if parts[0] != root {
        return Err(format!("the archive has an entry outside {root}/: {name:?}"));
    }
    Ok(name)
}

/// The entries of the tar archive `tar`
fn tar_entries(tar: impl Read, root: &str) -> Result<Vec<Entry>, String> {
    let damaged = |err: std::io::Error| format!("the tar archive is damaged: {err}");
    let mut archive = tar::Archive::new(tar);
    let mut entries = Vec::new();
    for entry in archive.entries().map_err(damaged)? {
        let mut entry = entry.map_err(damaged)?;
        let kind = entry.header().entry_type();
        if kind.is_pax_global_extensions() {
            continue;
        }
        let mut name = entry.path_bytes().into_owned();
        if kind.is_dir() {
            if !name.ends_with(b"/") {
                name.push(b'/');
            }
            entries.push(Entry {
                name: check_name(&name, root)?,
                data: None,
            });
        } else if kind.is_file() || kind.is_contiguous() {
            let name = check_name(&name, root)?;
            let mut data = Vec::new();
            entry.read_to_end(&mut data).map_err(damaged)?;
            entries.push(Entry { name, data: Some(data) });
        } else {
            return Err(format!(
                "the archive has an entry that is no file or directory: {:?}",
                String::from_utf8_lossy(&name)
            ));
        }
    }
    Ok(entries)
}

fn u16_at(b: &[u8], i: usize) -> Option<usize> {
    Some(u16::from_le_bytes(b.get(i..i + 2)?.try_into().ok()?) as usize)
}

fn u32_at(b: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_le_bytes(b.get(i..i + 4)?.try_into().ok()?))
}

/// The entries of the zip archive `zip`
fn zip_entries(zip: &[u8], root: &str) -> Result<Vec<Entry>, String> {
    let damaged = || "the zip archive is damaged".to_string();
    // The end of central directory record is in the last 22 + 65535 bytes (its comment)
    let eocd = (zip.len().saturating_sub(22 + 0xffff)..=zip.len().saturating_sub(22))
        .rev()
        .find(|&i| zip.len() >= 22 && u32_at(zip, i) == Some(0x0605_4b50))
        .ok_or_else(|| "the archive is not a zip archive".to_string())?;
    let count = u16_at(zip, eocd + 10).ok_or_else(damaged)?;
    let start = u32_at(zip, eocd + 16).ok_or_else(damaged)?;
    if count == 0xffff || start == u32::MAX {
        return Err("the zip archive needs ZIP64, which is not supported".into());
    }
    let mut offset = start as usize;
    let mut entries = Vec::new();
    for _ in 0..count {
        if u32_at(zip, offset) != Some(0x0201_4b50) {
            return Err(damaged());
        }
        let field16 = |i: usize| u16_at(zip, offset + i).ok_or_else(damaged);
        let field32 = |i: usize| u32_at(zip, offset + i).ok_or_else(damaged);
        let made_by = field16(4)?;
        let flags = field16(8)?;
        let method = field16(10)?;
        let crc = field32(16)?;
        let compressed = field32(20)?;
        let size = field32(24)?;
        let name_length = field16(28)?;
        let extra_length = field16(30)?;
        let comment_length = field16(32)?;
        let external = field32(38)?;
        let local = field32(42)?;
        let raw_name = zip.get(offset + 46..offset + 46 + name_length).ok_or_else(damaged)?;
        // Names without the UTF-8 flag are CP437, of which ASCII is a subset
        let name_bytes = if flags & 0x800 == 0 && !raw_name.is_ascii() {
            return Err(format!(
                "the archive has an entry whose path is not ASCII or UTF-8: {:?}",
                String::from_utf8_lossy(raw_name)
            ));
        } else {
            raw_name
        };
        offset += 46 + name_length + extra_length + comment_length;
        if flags & 0x1 != 0 {
            return Err(format!(
                "the zip archive has an encrypted entry: {:?}",
                String::from_utf8_lossy(name_bytes)
            ));
        }
        if compressed == u32::MAX || size == u32::MAX || local == u32::MAX {
            return Err("the zip archive needs ZIP64, which is not supported".into());
        }
        // Unix file types, when the archive was made on Unix
        if made_by >> 8 == 3 {
            let kind = (external >> 16) & 0o170000;
            if kind != 0 && kind != 0o040000 && kind != 0o100000 {
                return Err(format!(
                    "the archive has an entry that is no file or directory: {:?}",
                    String::from_utf8_lossy(name_bytes)
                ));
            }
        }
        let name = check_name(name_bytes, root)?;
        if name.ends_with('/') {
            entries.push(Entry { name, data: None });
            continue;
        }
        let local = local as usize;
        if u32_at(zip, local) != Some(0x0403_4b50) {
            return Err(damaged());
        }
        let data_start =
            local + 30 + u16_at(zip, local + 26).ok_or_else(damaged)? + u16_at(zip, local + 28).ok_or_else(damaged)?;
        let raw = zip.get(data_start..data_start + compressed as usize).ok_or_else(damaged)?;
        let data = match method {
            0 => raw.to_vec(),
            8 => {
                let mut data = Vec::with_capacity(size as usize);
                // At most one byte more than the size, which then fails the size check
                DeflateDecoder::new(raw)
                    .take(u64::from(size) + 1)
                    .read_to_end(&mut data)
                    .map_err(|_| format!("the zip archive has a damaged entry: {name:?}"))?;
                data
            }
            _ => {
                return Err(format!(
                    "the zip archive has an entry compressed with method {method}, which is not supported"
                ))
            }
        };
        if data.len() != size as usize || crc32fast::hash(&data) != crc {
            return Err(format!("the zip archive has a damaged entry: {name:?}"));
        }
        entries.push(Entry { name, data: Some(data) });
    }
    Ok(entries)
}

/// Unpacks `archive`, a `.zip` archive when `zip` holds, else a `.tar.gz` archive, whose entries
/// must all be below the directory `root`, into the directory `dest`: `dest/root/...`
pub fn unpack(archive: &[u8], zip: bool, root: &str, dest: &Path) -> Result<(), String> {
    let entries = if zip {
        zip_entries(archive, root)?
    } else {
        tar_entries(GzDecoder::new(archive), root)?
    };
    let io = |path: &Path, err: std::io::Error| format!("{}: {err}", path.display());
    for entry in entries {
        let target: PathBuf = entry
            .name
            .split('/')
            .filter(|p| !p.is_empty())
            .fold(dest.to_path_buf(), |p, c| p.join(c));
        match entry.data {
            None => fs::create_dir_all(&target).map_err(|e| io(&target, e))?,
            Some(data) => {
                if let Some(parent) = target.parent() {
                    fs::create_dir_all(parent).map_err(|e| io(parent, e))?;
                }
                // create_new: an archive that has a file twice fails
                let mut file = fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&target)
                    .map_err(|e| io(&target, e))?;
                file.write_all(&data).map_err(|e| io(&target, e))?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::test_util::TempDir;
    use flate2::write::{DeflateEncoder, GzEncoder};
    use flate2::Compression;

    const ROOT: &str = "zig-analyzer-v9.9.9-aarch64-linux-ReleaseSafe";

    pub(crate) fn gzip(data: &[u8]) -> Vec<u8> {
        let mut e = GzEncoder::new(Vec::new(), Compression::default());
        e.write_all(data).unwrap();
        e.finish().unwrap()
    }

    /// A tar archive of `(name, kind, data)` entries; names up to 100 bytes go into the header
    /// unchanged, so that the rejections can be tested, longer ones into GNU long name entries
    pub(crate) fn tar_with(entries: &[(&str, tar::EntryType, &[u8])]) -> Vec<u8> {
        let mut b = tar::Builder::new(Vec::new());
        for (name, kind, data) in entries {
            let mut h = tar::Header::new_gnu();
            h.set_entry_type(*kind);
            h.set_size(data.len() as u64);
            h.set_mode(if *kind == tar::EntryType::Directory { 0o755 } else { 0o644 });
            if kind.is_symlink() || kind.is_hard_link() {
                h.set_link_name("/etc/passwd").unwrap();
            }
            if name.len() <= 100 {
                h.as_gnu_mut().unwrap().name[..name.len()].copy_from_slice(name.as_bytes());
                h.set_cksum();
                b.append(&h, *data).unwrap();
            } else {
                b.append_data(&mut h, name, *data).unwrap();
            }
        }
        b.into_inner().unwrap()
    }

    /// A zip archive of `(name, data, method, unix mode)` entries
    pub(crate) fn zip_with(entries: &[(&str, &[u8], u16, Option<u32>)]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut central = Vec::new();
        for (name, data, method, mode) in entries {
            let packed = if *method == 8 {
                let mut e = DeflateEncoder::new(Vec::new(), Compression::default());
                e.write_all(data).unwrap();
                e.finish().unwrap()
            } else {
                data.to_vec()
            };
            let crc = crc32fast::hash(data);
            let local = out.len() as u32;
            out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
            for v in [20u16, 0x800, *method, 0, 0] {
                out.extend_from_slice(&v.to_le_bytes());
            }
            for v in [crc, packed.len() as u32, data.len() as u32] {
                out.extend_from_slice(&v.to_le_bytes());
            }
            out.extend_from_slice(&(name.len() as u16).to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(name.as_bytes());
            out.extend_from_slice(&packed);

            let made_by: u16 = if mode.is_some() { 3 << 8 | 20 } else { 20 };
            central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
            for v in [made_by, 20, 0x800, *method, 0, 0] {
                central.extend_from_slice(&v.to_le_bytes());
            }
            for v in [crc, packed.len() as u32, data.len() as u32] {
                central.extend_from_slice(&v.to_le_bytes());
            }
            for v in [name.len() as u16, 0, 0, 0, 0] {
                central.extend_from_slice(&v.to_le_bytes());
            }
            central.extend_from_slice(&(mode.unwrap_or(0) << 16).to_le_bytes());
            central.extend_from_slice(&local.to_le_bytes());
            central.extend_from_slice(name.as_bytes());
        }
        let start = out.len() as u32;
        out.extend_from_slice(&central);
        out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        for v in [0u16, 0, entries.len() as u16, entries.len() as u16] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out.extend_from_slice(&(central.len() as u32).to_le_bytes());
        out.extend_from_slice(&start.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out
    }

    fn files(dir: &Path) -> Vec<(String, Vec<u8>)> {
        let mut out = Vec::new();
        fn walk(dir: &Path, base: &Path, out: &mut Vec<(String, Vec<u8>)>) {
            let mut entries: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect();
            entries.sort();
            for p in entries {
                let rel = p.strip_prefix(base).unwrap().to_string_lossy().replace('\\', "/");
                if p.is_dir() {
                    out.push((rel + "/", Vec::new()));
                    walk(&p, base, out);
                } else {
                    out.push((rel, fs::read(&p).unwrap()));
                }
            }
        }
        walk(dir, dir, &mut out);
        out
    }

    fn long_name() -> String {
        format!("{ROOT}/{}/zig-analyzer", "d".repeat(120))
    }

    fn sample() -> Vec<(String, Vec<u8>)> {
        vec![
            (format!("{ROOT}/"), Vec::new()),
            (format!("{ROOT}/zig-analyzer"), b"#!/bin/sh\necho 9.9.9\n".to_vec()),
            (format!("{ROOT}/zig-analyzer.dSYM/Contents/Info.plist"), vec![7u8; 3000]),
            (long_name(), b"long".to_vec()),
        ]
    }

    fn unpacked(archive: &[u8], zip: bool) -> Result<Vec<(String, Vec<u8>)>, String> {
        let dir = TempDir::new();
        unpack(archive, zip, ROOT, dir.path())?;
        Ok(files(dir.path()))
    }

    fn expected() -> Vec<(String, Vec<u8>)> {
        let mut want: Vec<(String, Vec<u8>)> = Vec::new();
        for (name, data) in sample() {
            let mut prefix = String::new();
            let parts: Vec<&str> = name.trim_end_matches('/').split('/').collect();
            for p in &parts[..parts.len() - 1] {
                prefix += p;
                prefix += "/";
                if !want.iter().any(|(n, _)| *n == prefix) {
                    want.push((prefix.clone(), Vec::new()));
                }
            }
            if !want.iter().any(|(n, _)| *n == name) {
                want.push((name, data));
            }
        }
        want.sort();
        want
    }

    fn sorted(mut v: Vec<(String, Vec<u8>)>) -> Vec<(String, Vec<u8>)> {
        v.sort();
        v
    }

    #[test]
    fn tar_gz_written_by_the_tar_crate_unpacks_as_packed() {
        let mut b = tar::Builder::new(Vec::new());
        for (name, data) in sample() {
            let mut h = tar::Header::new_gnu();
            h.set_size(data.len() as u64);
            h.set_mode(0o755);
            h.set_entry_type(if name.ends_with('/') {
                tar::EntryType::Directory
            } else {
                tar::EntryType::Regular
            });
            b.append_data(&mut h, &name, data.as_slice()).unwrap();
        }
        let archive = gzip(&b.into_inner().unwrap());
        assert_eq!(sorted(unpacked(&archive, false).unwrap()), expected());
    }

    #[test]
    fn tar_gz_with_a_pax_path_unpacks_as_packed() {
        let mut b = tar::Builder::new(Vec::new());
        let name = long_name();
        b.append_pax_extensions([("path", name.as_bytes())]).unwrap();
        let mut h = tar::Header::new_ustar();
        h.set_path(format!("{ROOT}/placeholder")).unwrap();
        h.set_size(4);
        h.set_mode(0o644);
        h.set_cksum();
        b.append(&h, &b"long"[..]).unwrap();
        let archive = gzip(&b.into_inner().unwrap());
        let got = unpacked(&archive, false).unwrap();
        assert!(
            got.contains(&(name, b"long".to_vec())),
            "{:?}",
            got.iter().map(|(n, _)| n).collect::<Vec<_>>()
        );
        assert!(!got.iter().any(|(n, _)| n.ends_with("placeholder")));
    }

    #[test]
    fn tar_gz_with_a_ustar_prefix_unpacks_as_packed() {
        let mut b = tar::Builder::new(Vec::new());
        let name = format!("{ROOT}/{}/zig-analyzer", "p".repeat(60));
        let mut h = tar::Header::new_ustar();
        // Longer than the 100 bytes of the name field: set_path splits it into the prefix field
        h.set_path(&name).unwrap();
        assert_ne!(h.as_ustar().unwrap().prefix[0], 0);
        h.set_size(5);
        h.set_mode(0o644);
        h.set_cksum();
        b.append(&h, &b"ustar"[..]).unwrap();
        let archive = gzip(&b.into_inner().unwrap());
        assert!(unpacked(&archive, false).unwrap().contains(&(name, b"ustar".to_vec())));
    }

    /// The archives of the system's tar in each of its formats, when it is there
    #[test]
    fn tar_gz_written_by_the_system_tar_unpacks_as_packed() {
        let src = TempDir::new();
        for (name, data) in sample() {
            let p = src.path().join(&name);
            if name.ends_with('/') {
                fs::create_dir_all(&p).unwrap();
            } else {
                fs::create_dir_all(p.parent().unwrap()).unwrap();
                fs::write(&p, &data).unwrap();
            }
        }
        let Ok(version) = std::process::Command::new("tar").arg("--version").output() else {
            eprintln!("no tar: skipped");
            return;
        };
        let gnu = String::from_utf8_lossy(&version.stdout).contains("GNU tar");
        let mut ran = 0;
        for format in [if gnu { "gnu" } else { "gnutar" }, "pax"] {
            let out = src.path().join(format!("{format}.tar"));
            let status = std::process::Command::new("tar")
                .env("COPYFILE_DISABLE", "1")
                .arg(format!("--format={format}"))
                .arg("-cf")
                .arg(&out)
                .arg("-C")
                .arg(src.path())
                .arg(ROOT)
                .status()
                .unwrap();
            assert!(status.success(), "tar --format={format}");
            let archive = gzip(&fs::read(&out).unwrap());
            assert_eq!(
                sorted(unpacked(&archive, false).unwrap()),
                expected(),
                "tar --format={format}"
            );
            ran += 1;
        }
        assert_eq!(ran, 2);
    }

    #[test]
    fn tar_entries_outside_the_release_directory_are_rejected() {
        use tar::EntryType::{Directory, Regular};
        let long_dotdot = format!("{ROOT}/{}/../../../x", "d".repeat(120));
        let cases: Vec<(&str, Vec<u8>, &str)> = vec![
            ("..", tar_with(&[(&format!("{ROOT}/../x"), Regular, b"x")]), "invalid path"),
            ("absolute", tar_with(&[("/etc/x", Regular, b"x")]), "invalid path"),
            ("outside", tar_with(&[("other/x", Regular, b"x")]), "outside"),
            ("dot", tar_with(&[(&format!("{ROOT}/./x"), Regular, b"x")]), "invalid path"),
            (
                "backslash",
                tar_with(&[(&format!("{ROOT}\\..\\x"), Regular, b"x")]),
                "invalid path",
            ),
            ("long ..", tar_with(&[(&long_dotdot, Regular, b"x")]), "invalid path"),
            (
                "dir ..",
                tar_with(&[(&format!("{ROOT}/../"), Directory, b"")]),
                "invalid path",
            ),
        ];
        for (what, tar, want) in cases {
            let err = unpacked(&gzip(&tar), false).expect_err(what);
            assert!(err.contains(want), "{what}: {err}");
        }
    }

    #[test]
    fn tar_pax_path_outside_the_release_directory_is_rejected() {
        let mut b = tar::Builder::new(Vec::new());
        b.append_pax_extensions([("path", &b"../../x"[..])]).unwrap();
        let mut h = tar::Header::new_ustar();
        h.set_path(format!("{ROOT}/x")).unwrap();
        h.set_size(1);
        h.set_cksum();
        b.append(&h, &b"x"[..]).unwrap();
        let err = unpacked(&gzip(&b.into_inner().unwrap()), false).unwrap_err();
        assert!(err.contains("invalid path"), "{err}");
    }

    #[test]
    fn tar_links_and_special_files_are_rejected() {
        use tar::EntryType::*;
        for kind in [Symlink, Link, Char, Block, Fifo] {
            let tar = tar_with(&[(&format!("{ROOT}/zig-analyzer"), kind, b"")]);
            let dir = TempDir::new();
            let err = unpack(&gzip(&tar), false, ROOT, dir.path()).expect_err(&format!("{kind:?}"));
            assert!(err.contains("no file or directory"), "{kind:?}: {err}");
            assert!(files(dir.path()).is_empty(), "{kind:?} wrote files");
        }
    }

    #[test]
    fn damaged_tar_gz_is_rejected() {
        let tar = tar_with(&[(&format!("{ROOT}/zig-analyzer"), tar::EntryType::Regular, &[1u8; 2000])]);
        // Ends within the file
        assert!(unpacked(&gzip(&tar[..1024]), false).is_err());
        // Another checksum
        let mut bad = tar.clone();
        bad[148] ^= 1;
        let err = unpacked(&gzip(&bad), false).unwrap_err();
        assert!(err.contains("checksum"), "{err}");
        // No gzip
        assert!(unpacked(&tar, false).is_err());
        // A file twice
        let twice = tar_with(&[
            (&format!("{ROOT}/a"), tar::EntryType::Regular, b"1"),
            (&format!("{ROOT}/a"), tar::EntryType::Regular, b"2"),
        ]);
        assert!(unpacked(&gzip(&twice), false).is_err());
    }

    #[test]
    fn zip_unpacks_as_packed() {
        for method in [0u16, 8] {
            let entries: Vec<(String, Vec<u8>)> = sample();
            let refs: Vec<(&str, &[u8], u16, Option<u32>)> = entries
                .iter()
                .map(|(n, d)| {
                    (
                        n.as_str(),
                        d.as_slice(),
                        method,
                        if n.ends_with('/') { Some(0o040755) } else { None },
                    )
                })
                .collect();
            assert_eq!(
                sorted(unpacked(&zip_with(&refs), true).unwrap()),
                expected(),
                "method {method}"
            );
        }
    }

    #[test]
    fn zip_entries_that_are_unsafe_or_damaged_are_rejected() {
        let r = |n: &str| format!("{ROOT}/{n}");
        let cases: Vec<(&str, Vec<u8>, &str)> = vec![
            ("..", zip_with(&[(&r("../x"), b"x", 0, None)]), "invalid path"),
            ("backslash", zip_with(&[(&r("..\\x"), b"x", 0, None)]), "invalid path"),
            ("absolute", zip_with(&[("/x", b"x", 0, None)]), "invalid path"),
            ("outside", zip_with(&[("other/x", b"x", 0, None)]), "outside"),
            (
                "symlink",
                zip_with(&[(&r("zig-analyzer"), b"/etc/passwd", 0, Some(0o120777))]),
                "no file or directory",
            ),
            ("not zip", b"PK nothing".to_vec(), "not a zip"),
        ];
        for (what, zip, want) in cases {
            let err = unpacked(&zip, true).expect_err(what);
            assert!(err.contains(want), "{what}: {err}");
        }
        // Another CRC: flip a byte of the stored data
        let mut zip = zip_with(&[(&r("zig-analyzer"), b"0123456789", 0, None)]);
        let at = zip.windows(10).position(|w| w == b"0123456789").unwrap();
        zip[at] ^= 1;
        assert!(unpacked(&zip, true).unwrap_err().contains("damaged entry"));
    }
}
