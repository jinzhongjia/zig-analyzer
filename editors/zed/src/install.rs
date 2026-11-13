//! Installs a release of the server from GitHub into a directory: `<dir>/<release>/zig-analyzer`,
//! with `<dir>/current` naming the release in use. A release is installed only when the minisign
//! signature of its SHA256SUMS verifies with the release key, the trusted comment of the signature
//! names the release (`zig-analyzer <tag>`), and the archive has the SHA-256 that SHA256SUMS lists
//! for it.

use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::archive;

/// Where releases come from: the release page and the key that signs them
pub struct Source<'a> {
    pub releases: &'a str,
    /// The base64 line of `minisign.pub`
    pub public_key: &'a str,
}

/// The zig-analyzer releases, signed with the key of `minisign.pub` in the repository root
pub const GITHUB: Source<'static> = Source {
    releases: "https://github.com/jinzhongjia/zig-analyzer/releases",
    public_key: "RWRbma3B4tRgvIsJxiSxTvwoOWB6wvqxTEDgWVaJk0XMSeW9THbHBVj+",
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Optimize {
    ReleaseSafe,
    ReleaseFast,
}

impl Optimize {
    pub const ALL: [Optimize; 2] = [Optimize::ReleaseSafe, Optimize::ReleaseFast];

    pub fn name(self) -> &'static str {
        match self {
            Optimize::ReleaseSafe => "ReleaseSafe",
            Optimize::ReleaseFast => "ReleaseFast",
        }
    }

    pub fn parse(s: &str) -> Option<Optimize> {
        Optimize::ALL.into_iter().find(|o| o.name() == s)
    }
}

/// Which release to install
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Options {
    /// A release tag such as `v0.1.1`; the latest release when `None`
    pub version: Option<String>,
    pub optimize: Optimize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
    Linux,
    Macos,
    Windows,
}

/// The system that a release is built for
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Target {
    /// `aarch64` or `x86_64`
    pub arch: &'static str,
    pub os: Os,
}

impl Target {
    pub fn exe(self) -> &'static str {
        if self.os == Os::Windows {
            "zig-analyzer.exe"
        } else {
            "zig-analyzer"
        }
    }

    fn name(self) -> String {
        let os = match self.os {
            Os::Linux => "linux",
            Os::Macos => "macos",
            Os::Windows => "windows",
        };
        format!("{}-{os}", self.arch)
    }
}

pub enum Status {
    CheckingForUpdate,
    Downloading,
}

/// What the installer needs from the editor
pub trait Host {
    /// Downloads `url` into the file `to`, following redirects
    fn download(&mut self, url: &str, to: &Path) -> Result<(), String>;
    fn make_executable(&mut self, path: &Path) -> Result<(), String>;
    fn status(&mut self, status: Status);
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Installed {
    pub exe: PathBuf,
    /// `zig-analyzer-<tag>-<arch>-<os>-<optimize>`
    pub release: String,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Outcome {
    pub installed: Installed,
    pub tag: String,
    /// False when the release was installed already
    pub downloaded: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// A file of the release could not be downloaded
    Download(String),
    /// Anything else: the release does not verify, has no archive for the system, cannot be
    /// unpacked, ...
    Other(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Download(m) | Error::Other(m) => f.write_str(m),
        }
    }
}

impl From<String> for Error {
    fn from(message: String) -> Error {
        Error::Other(message)
    }
}

/// `v<major>.<minor>.<patch>` followed by `[0-9A-Za-z.-]*`
pub fn is_tag(s: &str) -> bool {
    let Some(mut rest) = s.strip_prefix('v') else { return false };
    for i in 0..3 {
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 {
            return false;
        }
        rest = &rest[digits..];
        if i < 2 {
            let Some(r) = rest.strip_prefix('.') else { return false };
            rest = r;
        }
    }
    rest.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

/// `zig-analyzer-v...` with no path separators or `..`; the arch may be `x86_64`
fn is_release_name(s: &str) -> bool {
    s.strip_prefix("zig-analyzer-v")
        .is_some_and(|r| !r.is_empty() && r.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)))
        && !s.contains("..")
}

/// `zig-analyzer-<tag>-<arch>-<os>-<optimize>`
fn release_name(tag: &str, target: Target, optimize: Optimize) -> String {
    format!("zig-analyzer-{tag}-{}-{}", target.name(), optimize.name())
}

/// The release installed in `dir`, when there is one
pub fn installed(dir: &Path, target: Target) -> Option<Installed> {
    let current = fs::read_to_string(dir.join("current")).ok()?;
    let release = current.lines().next()?.trim();
    if !is_release_name(release) {
        return None;
    }
    let exe = dir.join(release).join(target.exe());
    fs::metadata(&exe).ok()?.is_file().then(|| Installed {
        exe,
        release: release.to_string(),
    })
}

/// Removes the releases in `dir` other than `keep`; a release whose server still runs on Windows
/// stays
pub fn remove_others(dir: &Path, keep: &str) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with("zig-analyzer-") && name != keep {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

/// The SHA-256 that `sums` (SHA256SUMS) lists for `name`
fn listed_hash(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|line| {
        let (hash, file) = line.trim_end_matches('\r').split_once("  ")?;
        (file == name && hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit())).then(|| hash.to_ascii_lowercase())
    })
}

/// Verifies the signature of `sums` with `public_key` and returns the tag of its trusted comment
fn signed_tag(sums: &[u8], signature: &[u8], public_key: &str) -> Result<String, String> {
    let fail = |why: String| format!("SHA256SUMS: the signature does not verify with the release key ({why})");
    let key = minisign_verify::PublicKey::from_base64(public_key).map_err(|e| format!("the release key is invalid: {e}"))?;
    let signature = std::str::from_utf8(signature).map_err(|_| fail("the signature is no text".into()))?;
    let signature = minisign_verify::Signature::decode(signature).map_err(|e| fail(e.to_string()))?;
    key.verify(sums, &signature, false).map_err(|e| fail(e.to_string()))?;
    let comment = signature.trusted_comment();
    comment
        .strip_prefix("zig-analyzer ")
        .filter(|tag| is_tag(tag))
        .map(str::to_string)
        .ok_or_else(|| format!("SHA256SUMS: unexpected trusted comment {comment:?}"))
}

fn read(path: &Path) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|e| format!("{}: {e}", path.display()))
}

/// The SHA-256 of `data` in lowercase hex, as in SHA256SUMS
fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|b| format!("{b:02x}")).collect()
}

/// Installs a release into `dir`. A given release that is installed already needs no downloads;
/// the latest release needs those of SHA256SUMS and its signature to know which release it is.
pub fn install(host: &mut dyn Host, dir: &Path, options: &Options, source: &Source, target: Target) -> Result<Outcome, Error> {
    if let Some(v) = &options.version {
        if !is_tag(v) {
            return Err(Error::Other(format!("{v:?} is not a release tag (such as v0.1.1)")));
        }
        if let Some(current) = installed(dir, target) {
            if current.release == release_name(v, target, options.optimize) {
                return Ok(Outcome {
                    installed: current,
                    tag: v.clone(),
                    downloaded: false,
                });
            }
        }
    }
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    // Calls into an extension run one at a time, so that no other install uses the directory
    let tmp = dir.join(".tmp");
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
    let result = install_in(host, dir, &tmp, options, source, target);
    let _ = fs::remove_dir_all(&tmp);
    result
}

fn install_in(
    host: &mut dyn Host,
    dir: &Path,
    tmp: &Path,
    options: &Options,
    source: &Source,
    target: Target,
) -> Result<Outcome, Error> {
    host.status(Status::CheckingForUpdate);
    let base = match &options.version {
        None => format!("{}/latest/download", source.releases),
        Some(v) => format!("{}/download/{v}", source.releases),
    };
    let what = options.version.as_deref().unwrap_or("the latest release");
    let fetch = |host: &mut dyn Host, url: &str, to: &Path| -> Result<Vec<u8>, Error> {
        host.download(url, to)
            .map_err(|e| Error::Download(format!("downloading {url} failed ({what}): {e}")))?;
        Ok(read(to)?)
    };
    let sums = fetch(host, &format!("{base}/SHA256SUMS"), &tmp.join("SHA256SUMS"))?;
    let signature = fetch(host, &format!("{base}/SHA256SUMS.minisig"), &tmp.join("SHA256SUMS.minisig"))?;
    let tag = signed_tag(&sums, &signature, source.public_key)?;
    if let Some(v) = &options.version {
        if *v != tag {
            return Err(Error::Other(format!("SHA256SUMS is signed for {tag}, not {v}")));
        }
    }

    let release = release_name(&tag, target, options.optimize);
    let zip = target.os == Os::Windows;
    let archive_name = format!("{release}{}", if zip { ".zip" } else { ".tar.gz" });
    let sums = String::from_utf8_lossy(&sums);
    let hash = listed_hash(&sums, &archive_name).ok_or_else(|| format!("{tag} has no {archive_name}"))?;

    if let Some(current) = installed(dir, target) {
        if current.release == release {
            return Ok(Outcome {
                installed: current,
                tag,
                downloaded: false,
            });
        }
    }

    host.status(Status::Downloading);
    // From the checked release: `latest` may have moved on since SHA256SUMS was downloaded
    let archive = fetch(
        host,
        &format!("{}/download/{tag}/{archive_name}", source.releases),
        &tmp.join(&archive_name),
    )?;
    if sha256_hex(&archive) != hash {
        return Err(Error::Other(format!("{archive_name}: the SHA-256 does not match SHA256SUMS")));
    }

    let unpacked = tmp.join("unpacked");
    archive::unpack(&archive, zip, &release, &unpacked)?;
    let exe = unpacked.join(&release).join(target.exe());
    if !fs::metadata(&exe).is_ok_and(|m| m.is_file()) {
        return Err(Error::Other(format!("{archive_name} has no {release}/{}", target.exe())));
    }

    let dest = dir.join(&release);
    let _ = fs::remove_dir_all(&dest);
    fs::rename(unpacked.join(&release), &dest).map_err(|e| format!("{}: {e}", dest.display()))?;
    let exe = dest.join(target.exe());
    if !zip {
        host.make_executable(&exe).map_err(|e| format!("{}: {e}", exe.display()))?;
    }
    let current = dir.join("current");
    let current_tmp = tmp.join("current");
    fs::write(&current_tmp, format!("{release}\n")).map_err(|e| format!("{}: {e}", current_tmp.display()))?;
    // A host whose rename does not replace files gets the old `current` removed first
    fs::rename(&current_tmp, &current)
        .or_else(|_| {
            let _ = fs::remove_file(&current);
            fs::rename(&current_tmp, &current)
        })
        .map_err(|e| format!("{}: {e}", current.display()))?;
    Ok(Outcome {
        installed: Installed { exe, release },
        tag,
        downloaded: true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::archive::tests::{gzip, tar_with, zip_with};
    use crate::test_util::TempDir;
    use std::collections::HashMap;
    use std::io::Cursor;

    const RELEASES: &str = "https://releases.test/zig-analyzer/releases";
    const LINUX: Target = Target {
        arch: "x86_64",
        os: Os::Linux,
    };
    const WINDOWS: Target = Target {
        arch: "aarch64",
        os: Os::Windows,
    };

    /// A signing key for fake releases
    struct Key {
        pk: minisign::PublicKey,
        sk: minisign::SecretKey,
    }

    impl Key {
        fn new() -> Key {
            let minisign::KeyPair { pk, sk } = minisign::KeyPair::generate_unencrypted_keypair().unwrap();
            Key { pk, sk }
        }

        fn public(&self) -> String {
            self.pk.to_base64()
        }

        fn sign(&self, data: &[u8], comment: &str) -> Vec<u8> {
            minisign::sign(Some(&self.pk), &self.sk, Cursor::new(data), Some(comment), None)
                .unwrap()
                .to_string()
                .into_bytes()
        }
    }

    /// Fake releases served by URL, as GitHub serves them
    struct Releases {
        files: HashMap<String, Vec<u8>>,
        downloads: Vec<String>,
        statuses: Vec<&'static str>,
    }

    impl Host for Releases {
        fn download(&mut self, url: &str, to: &Path) -> Result<(), String> {
            self.downloads.push(url.to_string());
            let data = self.files.get(url).ok_or("download failed with status 404 Not Found")?;
            fs::write(to, data).map_err(|e| e.to_string())
        }

        fn make_executable(&mut self, path: &Path) -> Result<(), String> {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(path, fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
            }
            let _ = path;
            Ok(())
        }

        fn status(&mut self, status: Status) {
            self.statuses.push(match status {
                Status::CheckingForUpdate => "checking",
                Status::Downloading => "downloading",
            });
        }
    }

    fn archive_for(tag: &str, target: Target, optimize: Optimize) -> (String, Vec<u8>) {
        let release = release_name(tag, target, optimize);
        let exe = format!("{release}/{}", target.exe());
        let script = format!("#!/bin/sh\necho {}\n", &tag[1..]);
        if target.os == Os::Windows {
            (
                format!("{release}.zip"),
                zip_with(&[(&format!("{release}/"), b"", 0, None), (&exe, script.as_bytes(), 8, None)]),
            )
        } else {
            (
                format!("{release}.tar.gz"),
                gzip(&tar_with(&[
                    (&format!("{release}/"), tar::EntryType::Directory, b""),
                    (&exe, tar::EntryType::Regular, script.as_bytes()),
                ])),
            )
        }
    }

    impl Releases {
        fn new() -> Releases {
            Releases {
                files: HashMap::new(),
                downloads: Vec::new(),
                statuses: Vec::new(),
            }
        }

        /// Adds release `tag` for `targets`, signed by `key` with the trusted comment `comment`
        fn add(&mut self, key: &Key, tag: &str, comment: &str, targets: &[Target], latest: bool) {
            let mut sums = String::new();
            for &target in targets {
                for optimize in Optimize::ALL {
                    let (name, data) = archive_for(tag, target, optimize);
                    sums += &format!("{}  {name}\n", sha256_hex(&data));
                    self.files.insert(format!("{RELEASES}/download/{tag}/{name}"), data);
                }
            }
            let signature = key.sign(sums.as_bytes(), comment);
            for (name, data) in [("SHA256SUMS", sums.into_bytes()), ("SHA256SUMS.minisig", signature)] {
                if latest {
                    self.files.insert(format!("{RELEASES}/latest/download/{name}"), data.clone());
                }
                self.files.insert(format!("{RELEASES}/download/{tag}/{name}"), data);
            }
        }
    }

    fn options(version: Option<&str>, optimize: Optimize) -> Options {
        Options {
            version: version.map(str::to_string),
            optimize,
        }
    }

    fn safe() -> Options {
        options(None, Optimize::ReleaseSafe)
    }

    struct Fixture {
        key: Key,
        releases: Releases,
        dir: TempDir,
    }

    impl Fixture {
        /// No releases
        fn empty() -> Fixture {
            Fixture {
                key: Key::new(),
                releases: Releases::new(),
                dir: TempDir::new(),
            }
        }

        /// v9.9.8 and v9.9.9 (latest) for Linux and Windows
        fn new() -> Fixture {
            let mut f = Fixture::empty();
            f.add("v9.9.8", "zig-analyzer v9.9.8", &[LINUX, WINDOWS], false);
            f.add("v9.9.9", "zig-analyzer v9.9.9", &[LINUX, WINDOWS], true);
            f
        }

        fn add(&mut self, tag: &str, comment: &str, targets: &[Target], latest: bool) {
            self.releases.add(&self.key, tag, comment, targets, latest);
        }

        fn install(&mut self, options: &Options, target: Target) -> Result<Outcome, Error> {
            let public = self.key.public();
            let source = Source {
                releases: RELEASES,
                public_key: &public,
            };
            install(&mut self.releases, &self.dir.path().join("server"), options, &source, target)
        }

        fn server(&self) -> PathBuf {
            self.dir.path().join("server")
        }

        /// The entries of the install directory
        fn entries(&self) -> Vec<String> {
            let mut v: Vec<String> = fs::read_dir(self.server())
                .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
                .unwrap_or_default();
            v.sort();
            v
        }
    }

    #[test]
    fn tags() {
        for t in ["v0.1.1", "v10.20.30", "v0.2.0-rc.1", "v1.2.3-dev.4.a"] {
            assert!(is_tag(t), "{t}");
        }
        for t in [
            "0.1.1",
            "v0.1",
            "v0..1",
            "v0.1.1/../x",
            "latest",
            "v0.1.1 ",
            "",
            "v.1.1",
            "v0.1.1+meta",
        ] {
            assert!(!is_tag(t), "{t}");
        }
    }

    #[test]
    fn the_real_v0_1_1_sha256sums_verifies_with_the_release_key() {
        let sums = include_bytes!("../test/fixtures/SHA256SUMS");
        let signature = include_bytes!("../test/fixtures/SHA256SUMS.minisig");
        assert_eq!(signed_tag(sums, signature, GITHUB.public_key).unwrap(), "v0.1.1");
        let mut edited = sums.to_vec();
        edited[0] ^= 1;
        assert!(signed_tag(&edited, signature, GITHUB.public_key)
            .unwrap_err()
            .contains("does not verify"));
        // An edited trusted comment fails the global signature
        let edited = String::from_utf8(signature.to_vec())
            .unwrap()
            .replace("zig-analyzer v0.1.1", "zig-analyzer v0.1.2");
        assert!(signed_tag(sums, edited.as_bytes(), GITHUB.public_key)
            .unwrap_err()
            .contains("does not verify"));
        assert!(signed_tag(sums, signature, &Key::new().public())
            .unwrap_err()
            .contains("does not verify"));
        let hash = listed_hash(
            &String::from_utf8_lossy(sums),
            "zig-analyzer-v0.1.1-aarch64-macos-ReleaseSafe.tar.gz",
        );
        assert_eq!(hash.map(|h| h.len()), Some(64));
    }

    #[test]
    fn the_release_key_is_that_of_minisign_pub() {
        let file = include_str!("../../../minisign.pub");
        assert_eq!(file.lines().nth(1), Some(GITHUB.public_key));
    }

    #[test]
    fn the_latest_release_installs() {
        let mut f = Fixture::new();
        let out = f.install(&safe(), LINUX).unwrap();
        let release = release_name("v9.9.9", LINUX, Optimize::ReleaseSafe);
        assert_eq!(out.tag, "v9.9.9");
        assert!(out.downloaded);
        assert_eq!(
            out.installed,
            Installed {
                exe: f.server().join(&release).join("zig-analyzer"),
                release: release.clone()
            }
        );
        assert_eq!(fs::read_to_string(&out.installed.exe).unwrap(), "#!/bin/sh\necho 9.9.9\n");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&out.installed.exe).unwrap().permissions().mode() & 0o111, 0o111);
        }
        assert_eq!(installed(&f.server(), LINUX), Some(out.installed));
        assert_eq!(f.entries(), vec!["current".to_string(), release.clone()]);
        assert_eq!(
            f.releases.downloads,
            vec![
                format!("{RELEASES}/latest/download/SHA256SUMS"),
                format!("{RELEASES}/latest/download/SHA256SUMS.minisig"),
                format!("{RELEASES}/download/v9.9.9/{release}.tar.gz"),
            ]
        );
        assert_eq!(f.releases.statuses, vec!["checking", "downloading"]);
    }

    #[test]
    fn the_archive_comes_from_the_signed_tag_not_from_latest() {
        let mut f = Fixture::new();
        let release = release_name("v9.9.9", LINUX, Optimize::ReleaseSafe);
        f.releases
            .files
            .insert(format!("{RELEASES}/latest/download/{release}.tar.gz"), b"not this".to_vec());
        f.install(&safe(), LINUX).unwrap();
        assert!(!f
            .releases
            .downloads
            .iter()
            .any(|u| u.contains("latest/download/zig-analyzer")));
    }

    #[test]
    fn a_given_release_and_mode_install() {
        let mut f = Fixture::new();
        let out = f.install(&options(Some("v9.9.8"), Optimize::ReleaseFast), LINUX).unwrap();
        assert_eq!(out.installed.release, release_name("v9.9.8", LINUX, Optimize::ReleaseFast));
        assert_eq!(f.releases.downloads[0], format!("{RELEASES}/download/v9.9.8/SHA256SUMS"));
    }

    #[test]
    fn a_windows_release_installs_from_its_zip() {
        let mut f = Fixture::new();
        let out = f.install(&safe(), WINDOWS).unwrap();
        let release = release_name("v9.9.9", WINDOWS, Optimize::ReleaseSafe);
        assert_eq!(out.installed.exe, f.server().join(&release).join("zig-analyzer.exe"));
        assert!(f.releases.downloads[2].ends_with(&format!("{release}.zip")));
        assert_eq!(installed(&f.server(), WINDOWS), Some(out.installed));
    }

    #[test]
    fn reinstalling_the_latest_release_downloads_only_sha256sums() {
        let mut f = Fixture::new();
        let first = f.install(&safe(), LINUX).unwrap();
        f.releases.downloads.clear();
        let again = f.install(&safe(), LINUX).unwrap();
        assert!(!again.downloaded);
        assert_eq!(again.installed, first.installed);
        assert_eq!(
            f.releases.downloads,
            vec![
                format!("{RELEASES}/latest/download/SHA256SUMS"),
                format!("{RELEASES}/latest/download/SHA256SUMS.minisig")
            ]
        );
    }

    #[test]
    fn a_given_release_that_is_installed_needs_no_downloads() {
        let mut f = Fixture::new();
        let pinned = options(Some("v9.9.8"), Optimize::ReleaseSafe);
        let first = f.install(&pinned, LINUX).unwrap();
        f.releases.downloads.clear();
        f.releases.statuses.clear();
        // Offline
        f.releases.files.clear();
        let again = f.install(&pinned, LINUX).unwrap();
        assert_eq!(
            again,
            Outcome {
                installed: first.installed,
                tag: "v9.9.8".into(),
                downloaded: false
            }
        );
        assert!(f.releases.downloads.is_empty() && f.releases.statuses.is_empty());
        // Another mode of the release is another install
        let fast = f.install(&options(Some("v9.9.8"), Optimize::ReleaseFast), LINUX).unwrap_err();
        assert!(matches!(fast, Error::Download(_)), "{fast:?}");
    }

    #[test]
    fn failed_downloads_and_rejected_releases_are_told_apart() {
        let mut f = Fixture::new();
        f.releases.files.clear();
        let offline = f.install(&safe(), LINUX).unwrap_err();
        assert!(matches!(offline, Error::Download(_)), "{offline:?}");
        assert!(offline.to_string().starts_with(&format!(
            "downloading {RELEASES}/latest/download/SHA256SUMS failed (the latest release): "
        )));

        let mut f = Fixture::new();
        f.key = Key::new();
        let rejected = f.install(&safe(), LINUX).unwrap_err();
        assert!(matches!(rejected, Error::Other(_)), "{rejected:?}");

        // The archive is missing: a failed download too
        let mut f = Fixture::new();
        f.releases.files.retain(|url, _| !url.ends_with(".tar.gz"));
        assert!(matches!(f.install(&safe(), LINUX).unwrap_err(), Error::Download(_)));
    }

    #[test]
    fn the_previous_release_stays_until_it_is_removed() {
        let mut f = Fixture::new();
        let old = f.install(&options(Some("v9.9.8"), Optimize::ReleaseSafe), LINUX).unwrap();
        let new = f.install(&safe(), LINUX).unwrap();
        assert_eq!(installed(&f.server(), LINUX), Some(new.installed.clone()));
        assert!(old.installed.exe.is_file());
        remove_others(&f.server(), &new.installed.release);
        assert!(!old.installed.exe.exists());
        assert_eq!(f.entries(), vec!["current".to_string(), new.installed.release]);
    }

    /// Installs that must fail, with the text the error must hold
    fn rejected(f: &mut Fixture, options: &Options, want: &str) {
        let before = f.entries();
        let err = f.install(options, LINUX).expect_err(want).to_string();
        assert!(err.contains(want), "want {want:?}: {err}");
        // Also fails for a temporary directory left behind
        assert_eq!(f.entries(), before, "the install directory changed");
    }

    #[test]
    fn a_release_signed_with_another_key_is_rejected() {
        let mut f = Fixture::new();
        let other = Key::new();
        f.releases.add(&other, "v9.9.9", "zig-analyzer v9.9.9", &[LINUX], true);
        rejected(&mut f, &safe(), "does not verify");
    }

    #[test]
    fn a_release_signed_for_another_tag_is_rejected() {
        let mut f = Fixture::empty();
        f.add("v9.9.8", "zig-analyzer v9.9.9", &[LINUX], false);
        rejected(
            &mut f,
            &options(Some("v9.9.8"), Optimize::ReleaseSafe),
            "signed for v9.9.9, not v9.9.8",
        );
    }

    #[test]
    fn a_trusted_comment_that_names_no_release_is_rejected() {
        let mut f = Fixture::empty();
        f.add("v9.9.9", "timestamp:1700000000", &[LINUX], true);
        rejected(&mut f, &safe(), "unexpected trusted comment");
    }

    #[test]
    fn a_release_without_the_archive_is_rejected() {
        let mut f = Fixture::empty();
        f.add("v9.9.9", "zig-analyzer v9.9.9", &[WINDOWS], true);
        rejected(
            &mut f,
            &safe(),
            "v9.9.9 has no zig-analyzer-v9.9.9-x86_64-linux-ReleaseSafe.tar.gz",
        );
    }

    #[test]
    fn an_archive_with_another_sha256_is_rejected() {
        let mut f = Fixture::new();
        let release = release_name("v9.9.9", LINUX, Optimize::ReleaseSafe);
        let url = format!("{RELEASES}/download/v9.9.9/{release}.tar.gz");
        let (_, other) = archive_for("v9.9.8", LINUX, Optimize::ReleaseSafe);
        f.releases.files.insert(url, other);
        rejected(&mut f, &safe(), "the SHA-256 does not match SHA256SUMS");
    }

    #[test]
    fn a_release_that_does_not_exist_is_rejected() {
        let mut f = Fixture::new();
        rejected(&mut f, &options(Some("v1.0.0"), Optimize::ReleaseSafe), "404");
    }

    #[test]
    fn an_archive_without_the_server_is_rejected() {
        let mut f = Fixture::empty();
        let release = release_name("v9.9.9", LINUX, Optimize::ReleaseSafe);
        let data = gzip(&tar_with(&[(&format!("{release}/README"), tar::EntryType::Regular, b"x")]));
        let sums = format!("{}  {release}.tar.gz\n", sha256_hex(&data));
        let signature = f.key.sign(sums.as_bytes(), "zig-analyzer v9.9.9");
        f.releases
            .files
            .insert(format!("{RELEASES}/download/v9.9.9/{release}.tar.gz"), data);
        f.releases
            .files
            .insert(format!("{RELEASES}/latest/download/SHA256SUMS.minisig"), signature);
        f.releases
            .files
            .insert(format!("{RELEASES}/latest/download/SHA256SUMS"), sums.into_bytes());
        rejected(&mut f, &safe(), &format!("has no {release}/zig-analyzer"));
    }

    #[test]
    fn a_version_that_is_no_tag_is_rejected() {
        let mut f = Fixture::new();
        rejected(
            &mut f,
            &options(Some("../v9.9.9"), Optimize::ReleaseSafe),
            "is not a release tag",
        );
        assert!(f.releases.downloads.is_empty());
    }

    #[test]
    fn a_rejected_install_keeps_the_installed_release() {
        let mut f = Fixture::new();
        let old = f.install(&options(Some("v9.9.8"), Optimize::ReleaseSafe), LINUX).unwrap();
        let url = format!(
            "{RELEASES}/download/v9.9.9/{}.tar.gz",
            release_name("v9.9.9", LINUX, Optimize::ReleaseSafe)
        );
        f.releases.files.insert(url, b"damaged".to_vec());
        rejected(&mut f, &safe(), "SHA-256");
        assert_eq!(installed(&f.server(), LINUX), Some(old.installed));
    }

    #[test]
    fn a_current_file_that_names_no_release_is_ignored() {
        let f = Fixture::new();
        fs::create_dir_all(f.server().join("zig-analyzer-v9.9.9-x86_64-linux-ReleaseSafe")).unwrap();
        fs::write(
            f.server().join("zig-analyzer-v9.9.9-x86_64-linux-ReleaseSafe/zig-analyzer"),
            "x",
        )
        .unwrap();
        for current in ["../../etc", "zig-analyzer-v9.9.9/../../x", "", "other"] {
            fs::write(f.server().join("current"), current).unwrap();
            assert_eq!(installed(&f.server(), LINUX), None, "{current:?}");
        }
        fs::write(f.server().join("current"), "zig-analyzer-v9.9.9-x86_64-linux-ReleaseSafe\r\n").unwrap();
        assert!(installed(&f.server(), LINUX).is_some());
        // A release whose directory is gone
        fs::write(f.server().join("current"), "zig-analyzer-v9.9.8-x86_64-linux-ReleaseSafe\n").unwrap();
        assert_eq!(installed(&f.server(), LINUX), None);
    }

    #[test]
    fn a_leftover_temporary_directory_is_replaced() {
        let mut f = Fixture::new();
        fs::create_dir_all(f.server().join(".tmp/unpacked/zig-analyzer-v9.9.9-x86_64-linux-ReleaseSafe")).unwrap();
        f.install(&safe(), LINUX).unwrap();
        assert!(!f.server().join(".tmp").exists());
    }
}
