//! Helpers of the tests

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

/// A directory that is removed when the value is dropped
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new() -> TempDir {
        static COUNT: AtomicUsize = AtomicUsize::new(0);
        let n = COUNT.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("zed-zig-analyzer-test-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
