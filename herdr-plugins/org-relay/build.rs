//! Build provenance: bake the git SHA, dirty flag, and build instant into the
//! binary so the running daemon can attest WHAT it is (/health, /status,
//! --version) instead of provenance being inferred from tree cleanliness and
//! feature-sniffing. Falls back to "unknown" when git is absent (CI tarballs).

use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let dir = std::env::var("CARGO_MANIFEST_DIR").ok()?;
    let out = Command::new("git").arg("-C").arg(&dir).args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    // Empty stdout is a VALID answer (a clean tree's porcelain is empty);
    // only command failure is None.
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn main() {
    let sha = git(&["rev-parse", "--short=12", "HEAD"]).unwrap_or_else(|| "unknown".into());
    // Dirty means THIS crate's tracked tree differs from HEAD; the rest of a
    // monorepo does not taint the daemon's provenance.
    let dirty = match git(&["status", "--porcelain", "--", "."]) {
        Some(s) if !s.is_empty() => "dirty",
        Some(_) => "clean",
        None => "unknown",
    };
    let built_at = Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".into());

    println!("cargo:rustc-env=ORG_RELAY_GIT_SHA={sha}");
    println!("cargo:rustc-env=ORG_RELAY_GIT_DIRTY={dirty}");
    println!("cargo:rustc-env=ORG_RELAY_BUILT_AT={built_at}");

    // Re-run when the commit or index moves, so the baked SHA cannot go stale
    // behind a cargo cache: point at the enclosing repo's actual git dir.
    if let Some(gitdir) = git(&["rev-parse", "--absolute-git-dir"]) {
        println!("cargo:rerun-if-changed={gitdir}/HEAD");
        println!("cargo:rerun-if-changed={gitdir}/index");
    }
    println!("cargo:rerun-if-changed=build.rs");
}
