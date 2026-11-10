use zed_extension_api::{self as zed, serde_json, settings::LspSettings, LanguageServerId, Result};

/// The name of the language server, in `extension.toml` and in the `lsp` section of Zed's settings
const SERVER: &str = "zig-analyzer";

struct ZigAnalyzerExtension;

impl zed::Extension for ZigAnalyzerExtension {
    fn new() -> Self {
        ZigAnalyzerExtension
    }

    fn language_server_command(&mut self, _id: &LanguageServerId, worktree: &zed::Worktree) -> Result<zed::Command> {
        let binary = LspSettings::for_worktree(SERVER, worktree).ok().and_then(|s| s.binary);
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
            None => worktree.which(SERVER).ok_or_else(|| {
                format!("`{SERVER}` was not found in PATH: install it, or set `lsp.{SERVER}.binary.path` in the settings")
            })?,
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

/// The server settings: `lsp.zig-analyzer.settings`, or else `initialization_options`
fn server_settings(worktree: &zed::Worktree) -> serde_json::Value {
    let settings = LspSettings::for_worktree(SERVER, worktree).ok();
    settings
        .as_ref()
        .and_then(|s| s.settings.clone())
        .or_else(|| settings.and_then(|s| s.initialization_options))
        .unwrap_or_else(|| serde_json::json!({}))
}

zed::register_extension!(ZigAnalyzerExtension);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_configuration_is_keyed_by_the_server_name() {
        let v = serde_json::json!({ SERVER: serde_json::json!({ "build": { "args": ["-Dx"] } }) });
        assert_eq!(v["zig-analyzer"]["build"]["args"][0], "-Dx");
    }
}
