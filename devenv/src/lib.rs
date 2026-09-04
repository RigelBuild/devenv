// SecretsNeedPrompting fields trigger unused_assignments due to cross-crate usage (rustc 1.93)
#![allow(unused_assignments)]

pub mod backend;
pub mod changelog;
pub mod cli;
pub mod commands;
pub mod console;
mod devenv;
pub mod lsp;
pub mod mcp;
pub mod nix_log_bridge;
pub mod reload;
pub(crate) mod shell_env;
pub mod terminal;
pub mod tracing;
pub use devenv_processes as processes;
mod util;

#[cfg(feature = "snix")]
pub use devenv_snix_backend;

pub use devenv::{
    DIRENVRC, DIRENVRC_VERSION, Devenv, DevenvOptions, ProcessMode, ProcessOptions, RunMode,
    SecretsNeedPrompting, SecretsPromptSource, ShellCommand, format_shell_exports, is_ai_agent,
    load_cachix_secretspec,
};
pub use devenv_tasks as tasks;

// Re-export common subsystem crates for convenience.
pub use devenv_activity as activity;
pub use devenv_tui as tui;
pub use tokio_shutdown;

// Re-export core types from devenv-core for convenience
pub use devenv_core::{
    Backend, BuildOptions, CacheSettings, CachixCacheInfo, CachixManager, CachixPaths, Config,
    DevenvPaths, Evaluator, InputOverrides, NixArgs, NixSettings, SecretOptions, SecretSettings,
    SecretspecData, ShellSettings, VerbosityLevel, config, default_system,
};

/// Returns true if this binary was NOT built from a release.
///
/// DEVENV_IS_RELEASE is set by build.rs: either from the DEVENV_IS_RELEASE
/// env var (flake/CI builds) or auto-detected via git tag (local builds).
pub fn is_development_version() -> bool {
    !matches!(env!("DEVENV_IS_RELEASE"), "true" | "1")
}

/// Process-wide serialization for tests that mutate the environment or the
/// current working directory. Env access is process-global and edition-2024
/// makes `set_var`/`remove_var` `unsafe`; std's contract requires that no other
/// thread reads or writes the environment concurrently. The default libtest
/// harness runs this lib target's tests multi-threaded in ONE binary, so every
/// test guard in the lib crate that touches env/cwd MUST take this ONE lock — a
/// per-module mutex only serializes within its own module and races the others.
/// (The `devenv` bin target is a separate test binary and keeps its own
/// `PROCESS_STATE_LOCK`.) Held for a guard's lifetime and released after it
/// restores the state it changed.
#[cfg(test)]
pub(crate) static TEST_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
