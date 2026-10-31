// Shared by build.rs (via include!) and the crate's tests: keep this file to
// plain items with no `use` of crate code, so it compiles in both places.

/// Strip URL userinfo (`scheme://user:token@host/...` -> `scheme://host/...`)
/// before a git remote is baked into the binary, where --version, /health,
/// /status and relay_status would publish it. An scp-style remote
/// (`git@github.com:org/repo.git`) carries no secret and stays as it is.
pub fn redact_remote(url: &str) -> String {
    let Some(scheme_end) = url.find("://") else {
        return url.to_string();
    };
    let rest = &url[scheme_end + 3..];
    let authority_end = rest.find('/').unwrap_or(rest.len());
    match rest[..authority_end].rfind('@') {
        Some(at) => format!("{}{}", &url[..scheme_end + 3], &rest[at + 1..]),
        None => url.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::redact_remote;

    #[test]
    fn userinfo_is_stripped_and_everything_else_kept() {
        assert_eq!(
            redact_remote("https://user:ghp_SECRET@github.com/skylence-org/repo.git"),
            "https://github.com/skylence-org/repo.git"
        );
        assert_eq!(redact_remote("https://ghp_SECRET@github.com/o/r"), "https://github.com/o/r");
        assert_eq!(redact_remote("https://github.com/o/r.git"), "https://github.com/o/r.git");
        assert_eq!(redact_remote("git@github.com:o/r.git"), "git@github.com:o/r.git");
        assert_eq!(redact_remote("ssh://git@host:22/o/r"), "ssh://host:22/o/r");
        assert_eq!(redact_remote("https://host/path@with-at"), "https://host/path@with-at");
        assert_eq!(redact_remote("unknown"), "unknown");
    }
}
