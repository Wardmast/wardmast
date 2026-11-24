//! Where the release keeps its data (`WARDMAST_DATA_HOME`) when nothing says
//! otherwise.
//!
//! The variable chain is the same one `Wardmast.Env.data_home/0` and
//! `rel/env.sh.eex` use: `WARDMAST_DATA_HOME`, then the legacy `ARB_DATA_HOME`
//! (empty counts as unset). What differs is the last resort: a bundled macOS
//! app keeps its data where macOS apps do, `~/Library/Application Support/Wardmast`,
//! everything else keeps `~/.wardmast`. The shell always hands the resolved
//! value to the release as `WARDMAST_DATA_HOME`, so server and shell agree and
//! the release's own `~/.wardmast` default never applies under the app.

use std::path::{Path, PathBuf};

/// The default data home for `os` (a `std::env::consts::OS` value) under `home`.
pub fn default_for(os: &str, home: &Path) -> PathBuf {
    if os == "macos" {
        home.join("Library")
            .join("Application Support")
            .join("Wardmast")
    } else {
        home.join(".wardmast")
    }
}

/// Resolve the data home with `var` as the environment and `os` as the platform.
pub fn resolve_with(var: &dyn Fn(&str) -> Option<String>, os: &str) -> Option<PathBuf> {
    var("WARDMAST_DATA_HOME")
        .or_else(|| var("ARB_DATA_HOME"))
        .map(PathBuf::from)
        .or_else(|| var("HOME").map(|h| default_for(os, Path::new(&h))))
}

/// [`resolve_with`] over the real environment and platform.
pub fn resolve() -> Option<PathBuf> {
    resolve_with(
        &|name| std::env::var(name).ok().filter(|v| !v.is_empty()),
        std::env::consts::OS,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |name| map.get(name).filter(|v| !v.is_empty()).cloned()
    }

    #[test]
    fn macos_defaults_to_application_support() {
        let got = resolve_with(&env(&[("HOME", "/Users/me")]), "macos");
        assert_eq!(
            got,
            Some(PathBuf::from(
                "/Users/me/Library/Application Support/Wardmast"
            ))
        );
    }

    #[test]
    fn other_platforms_keep_the_dot_directory() {
        let got = resolve_with(&env(&[("HOME", "/home/me")]), "linux");
        assert_eq!(got, Some(PathBuf::from("/home/me/.wardmast")));
    }

    #[test]
    fn explicit_variables_win_on_macos_too() {
        let e = env(&[
            ("HOME", "/Users/me"),
            ("WARDMAST_DATA_HOME", "/data/a"),
            ("ARB_DATA_HOME", "/data/b"),
        ]);
        assert_eq!(resolve_with(&e, "macos"), Some(PathBuf::from("/data/a")));
        let e = env(&[("HOME", "/Users/me"), ("ARB_DATA_HOME", "/data/b")]);
        assert_eq!(resolve_with(&e, "macos"), Some(PathBuf::from("/data/b")));
    }

    #[test]
    fn an_empty_wardmast_variable_falls_through_to_the_legacy_one() {
        let e = env(&[
            ("HOME", "/Users/me"),
            ("WARDMAST_DATA_HOME", ""),
            ("ARB_DATA_HOME", "/data/b"),
        ]);
        assert_eq!(resolve_with(&e, "macos"), Some(PathBuf::from("/data/b")));
    }

    #[test]
    fn no_home_and_no_variable_resolves_to_nothing() {
        assert_eq!(resolve_with(&env(&[]), "macos"), None);
    }
}
