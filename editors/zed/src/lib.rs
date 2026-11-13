use std::collections::HashMap;
use std::path::{Path, PathBuf};

use zed_extension_api::{
    self as zed, serde_json, settings::LspSettings, LanguageServerId, LanguageServerInstallationStatus, Result,
};

mod archive;
mod install;
#[cfg(test)]
mod test_util;

/// The name of the language server, in `extension.toml` and in the `lsp` section of Zed's settings
const SERVER: &str = "zig-analyzer";

/// The setting of the extension, in `lsp.zig-analyzer.settings`, that is not sent to the server
const DOWNLOAD: &str = "download";

/// The install directory, relative to the extension's work directory
const INSTALL_DIR: &str = "server";

struct ZigAnalyzerExtension {
    /// The server installed for each download setting in this session: only the first server start
    /// with a setting looks for the release
    installs: HashMap<install::Options, PathBuf>,
}

impl zed::Extension for ZigAnalyzerExtension {
    fn new() -> Self {
        ZigAnalyzerExtension {
            installs: HashMap::new(),
        }
    }

    fn language_server_command(&mut self, id: &LanguageServerId, worktree: &zed::Worktree) -> Result<zed::Command> {
        let lsp = LspSettings::for_worktree(SERVER, worktree).ok();
        let settings = raw_settings(lsp.as_ref());
        let binary = lsp.and_then(|s| s.binary);
        let args = binary.as_ref().and_then(|b| b.arguments.clone()).unwrap_or_default();
        // The shell environment gives the server the same PATH (and so the same `zig`) as a terminal
        let mut env = match zed::current_platform().0 {
            zed::Os::Mac | zed::Os::Linux => worktree.shell_env(),
            zed::Os::Windows => Vec::new(),
        };
        if let Some(extra) = binary.as_ref().and_then(|b| b.env.clone()) {
            env.retain(|(k, _)| !extra.contains_key(k));
            env.extend(extra);
        }
        let command = match binary.and_then(|b| b.path) {
            Some(path) => path,
            None => {
                let (_, download) = split_settings(settings);
                match download_options(download.as_ref())? {
                    None => worktree.which(SERVER).ok_or_else(not_found)?,
                    Some(options) => self.downloaded_server(id, &options)?,
                }
            }
        };
        Ok(zed::Command { command, args, env })
    }

    fn language_server_initialization_options(
        &mut self,
        _id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<Option<serde_json::Value>> {
        Ok(Some(server_settings(worktree)))
    }

    fn language_server_workspace_configuration(
        &mut self,
        _id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<Option<serde_json::Value>> {
        // Zed answers `workspace/configuration` for the `zig-analyzer` section with the value under
        // that key, and sends the whole object in `workspace/didChangeConfiguration`, where the
        // server accepts the `zig-analyzer` wrapper too
        Ok(Some(serde_json::json!({ SERVER: server_settings(worktree) })))
    }
}

impl ZigAnalyzerExtension {
    /// The server of the release that `options` selects, installed when it is not
    fn downloaded_server(&mut self, id: &LanguageServerId, options: &install::Options) -> Result<String> {
        let dir = Path::new(INSTALL_DIR);
        if let Some(exe) = self.installs.get(options) {
            if exe.is_file() {
                return Ok(exe.to_string_lossy().into_owned());
            }
        }
        let target = target().ok_or_else(|| {
            format!("there is no zig-analyzer release for this system: build it from source and set `lsp.{SERVER}.binary.path`")
        })?;
        let result = install::install(&mut ZedHost { id }, dir, options, &install::GITHUB, target);
        zed::set_language_server_installation_status(id, &LanguageServerInstallationStatus::None);
        match result {
            Ok(outcome) => {
                install::remove_others(dir, &outcome.installed.release);
                self.installs.insert(options.clone(), outcome.installed.exe.clone());
                Ok(outcome.installed.exe.to_string_lossy().into_owned())
            }
            Err(err) => fallback(options, err, install::installed(dir, target)).map(|i| i.exe.to_string_lossy().into_owned()),
        }
    }
}

/// The server after a failed install. When the latest release could not be downloaded (offline,
/// say) the installed release starts; any other failure is the error that Zed shows for the
/// server, so that a release that does not verify is never passed over silently.
fn fallback(
    options: &install::Options,
    err: install::Error,
    installed: Option<install::Installed>,
) -> Result<install::Installed> {
    let message = format!("installing zig-analyzer failed: {err}");
    match (
        options.version.is_none() && matches!(err, install::Error::Download(_)),
        installed,
    ) {
        (true, Some(installed)) => {
            eprintln!("{message}; starting the installed {}", installed.release);
            Ok(installed)
        }
        _ => Err(message),
    }
}

fn not_found() -> String {
    format!(
        "`{SERVER}` was not found in PATH: install it, set `lsp.{SERVER}.binary.path` in the settings, \
         or set `lsp.{SERVER}.settings.{DOWNLOAD}` to `true` to download a release"
    )
}

/// The release target of this system
fn target() -> Option<install::Target> {
    let (os, arch) = zed::current_platform();
    let arch = match arch {
        zed::Architecture::Aarch64 => "aarch64",
        zed::Architecture::X8664 => "x86_64",
        zed::Architecture::X86 => return None,
    };
    let os = match os {
        zed::Os::Mac => install::Os::Macos,
        zed::Os::Linux => install::Os::Linux,
        zed::Os::Windows => install::Os::Windows,
    };
    Some(install::Target { arch, os })
}

/// Downloads with Zed, which follows redirects and applies its proxy settings
struct ZedHost<'a> {
    id: &'a LanguageServerId,
}

impl install::Host for ZedHost<'_> {
    fn download(&mut self, url: &str, to: &Path) -> std::result::Result<(), String> {
        zed::download_file(url, &to.to_string_lossy(), zed::DownloadedFileType::Uncompressed)
    }

    fn make_executable(&mut self, path: &Path) -> std::result::Result<(), String> {
        zed::make_file_executable(&path.to_string_lossy())
    }

    fn status(&mut self, status: install::Status) {
        let status = match status {
            install::Status::CheckingForUpdate => LanguageServerInstallationStatus::CheckingForUpdate,
            install::Status::Downloading => LanguageServerInstallationStatus::Downloading,
        };
        zed::set_language_server_installation_status(self.id, &status);
    }
}

/// `lsp.zig-analyzer.settings`, or else `initialization_options`
fn raw_settings(settings: Option<&LspSettings>) -> serde_json::Value {
    settings
        .and_then(|s| s.settings.clone())
        .or_else(|| settings.and_then(|s| s.initialization_options.clone()))
        .unwrap_or_else(|| serde_json::json!({}))
}

/// Splits the settings into those of the server and the extension's `download` setting
fn split_settings(mut settings: serde_json::Value) -> (serde_json::Value, Option<serde_json::Value>) {
    let download = settings.as_object_mut().and_then(|o| o.remove(DOWNLOAD));
    (settings, download)
}

/// The server settings
fn server_settings(worktree: &zed::Worktree) -> serde_json::Value {
    split_settings(raw_settings(LspSettings::for_worktree(SERVER, worktree).ok().as_ref())).0
}

/// The release that the `download` setting selects: none when it is unset or `false`; the latest
/// ReleaseSafe build for `true`; `{ "version": "latest" | "<tag>", "optimize": "ReleaseSafe" |
/// "ReleaseFast" }` for another one
fn download_options(value: Option<&serde_json::Value>) -> Result<Option<install::Options>> {
    use serde_json::Value;
    let invalid = |why: String| format!("`lsp.{SERVER}.settings.{DOWNLOAD}`: {why}");
    let mut options = install::Options {
        version: None,
        optimize: install::Optimize::ReleaseSafe,
    };
    match value {
        None | Some(Value::Null) | Some(Value::Bool(false)) => return Ok(None),
        Some(Value::Bool(true)) => {}
        Some(Value::Object(fields)) => {
            for (key, value) in fields {
                match (key.as_str(), value) {
                    ("version", Value::String(v)) if v == "latest" => {}
                    ("version", Value::String(v)) if install::is_tag(v) => options.version = Some(v.clone()),
                    ("version", v) => {
                        return Err(invalid(format!(
                            "version must be \"latest\" or a release tag such as \"v0.1.1\", not {v}"
                        )))
                    }
                    ("optimize", Value::String(v)) if install::Optimize::parse(v).is_some() => {
                        options.optimize = install::Optimize::parse(v).unwrap();
                    }
                    ("optimize", v) => {
                        return Err(invalid(format!(
                            "optimize must be \"ReleaseSafe\" or \"ReleaseFast\", not {v}"
                        )))
                    }
                    (k, _) => return Err(invalid(format!("unknown option \"{k}\" (there are version and optimize)"))),
                }
            }
        }
        Some(v) => {
            return Err(invalid(format!(
                "must be true, false, or an object with version and optimize, not {v}"
            )))
        }
    }
    Ok(Some(options))
}

zed::register_extension!(ZigAnalyzerExtension);

#[cfg(test)]
mod tests {
    use super::*;
    use install::{Optimize, Options};
    use serde_json::json;

    #[test]
    fn workspace_configuration_is_keyed_by_the_server_name() {
        let v = serde_json::json!({ SERVER: serde_json::json!({ "build": { "args": ["-Dx"] } }) });
        assert_eq!(v["zig-analyzer"]["build"]["args"][0], "-Dx");
    }

    #[test]
    fn the_download_setting_is_not_sent_to_the_server() {
        let (server, download) = split_settings(json!({ "download": true, "build": { "args": ["-Dx"] } }));
        assert_eq!(server, json!({ "build": { "args": ["-Dx"] } }));
        assert_eq!(download, Some(json!(true)));
        assert_eq!(split_settings(json!({ "build": {} })), (json!({ "build": {} }), None));
        assert_eq!(split_settings(json!(null)), (json!(null), None));
    }

    #[test]
    fn settings_come_from_settings_else_initialization_options() {
        let lsp = |settings: Option<serde_json::Value>, init: Option<serde_json::Value>| LspSettings {
            binary: None,
            initialization_options: init,
            settings,
        };
        let s = lsp(Some(json!({ "a": 1 })), Some(json!({ "b": 2 })));
        assert_eq!(raw_settings(Some(&s)), json!({ "a": 1 }));
        assert_eq!(raw_settings(Some(&lsp(None, Some(json!({ "b": 2 }))))), json!({ "b": 2 }));
        assert_eq!(raw_settings(None), json!({}));
    }

    #[test]
    fn download_is_off_unless_it_is_set() {
        assert_eq!(download_options(None), Ok(None));
        assert_eq!(download_options(Some(&json!(false))), Ok(None));
        assert_eq!(download_options(Some(&json!(null))), Ok(None));
    }

    #[test]
    fn download_settings_select_a_release() {
        let latest_safe = Options {
            version: None,
            optimize: Optimize::ReleaseSafe,
        };
        assert_eq!(download_options(Some(&json!(true))), Ok(Some(latest_safe.clone())));
        assert_eq!(download_options(Some(&json!({}))), Ok(Some(latest_safe.clone())));
        assert_eq!(download_options(Some(&json!({ "version": "latest" }))), Ok(Some(latest_safe)));
        assert_eq!(
            download_options(Some(&json!({ "version": "v0.1.1", "optimize": "ReleaseFast" }))),
            Ok(Some(Options {
                version: Some("v0.1.1".into()),
                optimize: Optimize::ReleaseFast
            }))
        );
    }

    #[test]
    fn invalid_download_settings_are_errors() {
        for (v, want) in [
            (json!("yes"), "must be true, false, or an object"),
            (json!(1), "must be true, false, or an object"),
            (json!({ "version": "0.1.1" }), "version must be"),
            (json!({ "version": "../v0.1.1" }), "version must be"),
            (json!({ "version": 1 }), "version must be"),
            (json!({ "optimize": "Debug" }), "optimize must be"),
            (json!({ "mirror": "x" }), "unknown option \"mirror\""),
        ] {
            let err = download_options(Some(&v)).expect_err(&v.to_string());
            assert!(
                err.starts_with("`lsp.zig-analyzer.settings.download`: ") && err.contains(want),
                "{v}: {err}"
            );
        }
    }

    #[test]
    fn only_a_failed_download_of_the_latest_release_starts_the_installed_one() {
        use install::{Error, Installed};
        let latest = Options {
            version: None,
            optimize: Optimize::ReleaseSafe,
        };
        let pinned = Options {
            version: Some("v0.1.1".into()),
            optimize: Optimize::ReleaseSafe,
        };
        let installed = || {
            Some(Installed {
                exe: "server/zig-analyzer-v0.1.0-aarch64-macos-ReleaseSafe/zig-analyzer".into(),
                release: "zig-analyzer-v0.1.0-aarch64-macos-ReleaseSafe".into(),
            })
        };
        let offline = || Error::Download("downloading x failed (the latest release): offline".into());
        let rejected = || Error::Other("SHA256SUMS: the signature does not verify with the release key (x)".into());
        assert_eq!(fallback(&latest, offline(), installed()), Ok(installed().unwrap()));
        assert_eq!(
            fallback(&latest, offline(), None),
            Err("installing zig-analyzer failed: downloading x failed (the latest release): offline".into())
        );
        assert_eq!(
            fallback(&latest, rejected(), installed()),
            Err("installing zig-analyzer failed: SHA256SUMS: the signature does not verify with the release key (x)".into())
        );
        assert!(fallback(&pinned, offline(), installed()).is_err());
        assert!(fallback(&pinned, rejected(), installed()).is_err());
    }

    #[test]
    fn the_not_found_message_names_the_settings() {
        let m = not_found();
        assert!(
            m.contains("lsp.zig-analyzer.binary.path") && m.contains("lsp.zig-analyzer.settings.download"),
            "{m}"
        );
    }
}
