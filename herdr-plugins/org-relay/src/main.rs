//! org-relay 1.0: durable MCP message bus for the herdr agent-org.
//!
//! Data plane: SQLite queue (WAL), explicit consume (queue.rs). Wake plane:
//! TASK-BACKED `relay_await` — a tasks-capable client (SEP-2663,
//! io.modelcontextprotocol/tasks) gets a task handle immediately; any other
//! client holds the call in-turn, and Claude Code >= 2.1.212 auto-backgrounds
//! that hold at ~2 minutes into a native background task whose settlement
//! starts the recipient's next turn. Either way ONE long await covers a whole
//! idle period; the 0.5.x 50-second re-arm loop is retired with the
//! hand-rolled transport that required it.
//!
//! Transport: rmcp streamable HTTP behind axum (the binary-skyline stack),
//! serving POST/GET/DELETE /mcp plus a bare GET /health. Wire an agent with:
//! `claude mcp add --transport http relay http://127.0.0.1:7431/mcp`
//!
//! Guide gate: messaging tools refuse until the session reads relay://guide
//! (or calls relay_guide); strictly per-session and in-memory — every
//! session reads the short contract once (guide.rs, server.rs). Sessions
//! exist only for the legacy lifecycle (protocol < 2026-07-28); SEP-2567
//! clients are served statelessly with a fresh RelayServer per request, so
//! for them the gate is skipped rather than permanently shut (server.rs).
//! Nudge watchdog: the NET for recipients with backlog and no live await
//! coverage, where task-backed coverage requires tasks/get poll liveness
//! (nudge.rs, queue.rs).

mod guide;
mod nudge;
mod queue;
mod server;

use rmcp::transport::streamable_http_server::{
    session::local::LocalSessionManager, StreamableHttpServerConfig, StreamableHttpService,
};
use std::sync::Arc;

/// Build provenance, baked by build.rs. The daemon attests WHAT it is;
/// nobody infers provenance from tree state again.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const GIT_SHA: &str = env!("ORG_RELAY_GIT_SHA");
pub const GIT_DIRTY: &str = env!("ORG_RELAY_GIT_DIRTY");
pub const BUILT_AT: &str = env!("ORG_RELAY_BUILT_AT");

fn build_info() -> serde_json::Value {
    serde_json::json!({
        "version": VERSION, "sha": GIT_SHA, "dirty": GIT_DIRTY == "dirty",
        "built_at": BUILT_AT,
    })
}

fn build_router() -> axum::Router {
    use axum::routing::{get, post};

    // JSON with status:"ok" so relay-ctl's `grep -q ok` liveness probe keeps
    // matching while the payload self-attests version + sha.
    async fn health() -> impl axum::response::IntoResponse {
        (
            [(axum::http::header::CONTENT_TYPE, "application/json")],
            serde_json::json!({"status": "ok", "build": build_info()}).to_string(),
        )
    }

    // Plain-HTTP mirror of the relay_status tool for CLI and hook consumers
    // (relay-ctl status, org-stop-gate): no MCP handshake, no session, no
    // guide gate — the same never-gated diagnostics the tool exposes.
    async fn status() -> impl axum::response::IntoResponse {
        let body = tokio::task::spawn_blocking(|| {
            let mut v = queue::op_sync("relay_status", &serde_json::json!({}))
                .unwrap_or_else(|e| serde_json::json!({"error": e}));
            if let Some(o) = v.as_object_mut() {
                o.insert("build".into(), build_info());
            }
            v.to_string()
        })
        .await
        .unwrap_or_else(|e| format!("{{\"error\":\"{e}\"}}"));
        ([(axum::http::header::CONTENT_TYPE, "application/json")], body)
    }
    // Plain-HTTP mirror of relay_send for non-MCP producers on this box —
    // CI notify steps, shell hooks — that have one message to drop and no
    // business doing an MCP handshake. Loopback bind is the trust boundary,
    // exactly as for /mcp (any local process can already speak the full tool
    // surface); the guide gate is a session contract and sessions do not
    // exist here. Same op layer as the tool: durable enqueue + audit event +
    // in-process wake of a live awaiter.
    async fn send(body: String) -> impl axum::response::IntoResponse {
        let json_ct = [(axum::http::header::CONTENT_TYPE, "application/json")];
        let args: serde_json::Value = match serde_json::from_str(&body) {
            Ok(v) => v,
            Err(e) => {
                return (
                    axum::http::StatusCode::BAD_REQUEST,
                    json_ct,
                    serde_json::json!({"error": format!("invalid JSON body: {e}")}).to_string(),
                );
            }
        };
        let (code, out) = tokio::task::spawn_blocking(move || {
            match queue::op_sync("relay_send", &args) {
                Ok(v) => (axum::http::StatusCode::OK, v.to_string()),
                Err(e) => (
                    axum::http::StatusCode::BAD_REQUEST,
                    serde_json::json!({"error": e}).to_string(),
                ),
            }
        })
        .await
        .unwrap_or_else(|e| {
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                format!("{{\"error\":\"{e}\"}}"),
            )
        });
        (code, json_ct, out)
    }
    // SESSION KEEP-ALIVE (field-measured 2026-08-05, todo-app org debrief):
    // rmcp's default kills a session after 300s of bus inactivity, which is
    // NORMAL for an org agent between beats — every kill forced a client
    // re-initialize and re-armed the per-session guide gate (one relay_guide
    // round trip per flap, several per session). Org sessions live all day:
    // default 12h, ORG_RELAY_SESSION_KEEP_ALIVE_S overrides, 0 disables the
    // reaper entirely (fine on loopback; the reaper exists for proxied
    // half-dead TCP, which localhost does not produce).
    let keep_alive_s = std::env::var("ORG_RELAY_SESSION_KEEP_ALIVE_S")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(43_200);
    let mut sm = LocalSessionManager::default();
    sm.session_config.keep_alive = if keep_alive_s == 0 {
        None
    } else {
        Some(std::time::Duration::from_secs(keep_alive_s))
    };
    let session_manager = Arc::new(sm);
    let service: StreamableHttpService<server::RelayServer, LocalSessionManager> =
        StreamableHttpService::new(
            || Ok(server::RelayServer::new()),
            session_manager,
            StreamableHttpServerConfig::default(),
        );

    axum::Router::new()
        .nest_service("/mcp", service)
        .route("/health", get(health))
        .route("/status", get(status))
        .route("/send", post(send))
        .layer(tower_http::limit::RequestBodyLimitLayer::new(1024 * 1024))
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
}

#[tokio::main]
async fn main() {
    // Self-attestation for installers and humans: `org-relay --version`.
    if std::env::args().any(|a| a == "--version" || a == "-V") {
        println!("org-relay {VERSION} {GIT_SHA} {GIT_DIRTY} {BUILT_AT}");
        return;
    }
    let port = std::env::var("ORG_RELAY_PORT").ok().and_then(|p| p.parse::<u16>().ok()).unwrap_or(7431);
    if let Err(e) = queue::open_db() {
        eprintln!("org-relay: cannot open {}: {e}", queue::db_path());
        std::process::exit(1);
    }
    let addr = format!("127.0.0.1:{port}");
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("org-relay: bind {addr} failed (already running?): {e}");
            std::process::exit(1);
        }
    };
    eprintln!("org-relay: serving MCP on http://{addr}/mcp  (db: {})", queue::db_path());
    if !nudge::nudge_enabled() {
        eprintln!("org-relay: nudge watchdog OFF (ORG_RELAY_NUDGE)");
    } else if let Some(h) = nudge::nudge_helper() {
        eprintln!(
            "org-relay: nudge watchdog on (poll {}s, grace {}s, cooldown {}s, helper {})",
            queue::NUDGE_POLL_S,
            queue::NUDGE_GRACE_S,
            queue::NUDGE_COOLDOWN_S,
            h.display()
        );
        nudge::spawn_nudge_watchdog(h);
    } else {
        eprintln!("org-relay: nudge watchdog OFF — helper nudge-deliver not found beside the crate (set ORG_RELAY_NUDGE_HELPER)");
    }

    // Retention: consumed rows are history the audit stream already carries.
    // Daily prune, ORG_RELAY_RETAIN_DAYS (default 7, 0 disables).
    let retain_days = std::env::var("ORG_RELAY_RETAIN_DAYS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(7);
    if retain_days > 0 {
        std::thread::spawn(move || loop {
            match queue::prune_consumed(retain_days) {
                Ok(n) if n > 0 => queue::log_event(
                    "audit",
                    serde_json::json!({"event":"prune","deleted":n,"retain_days":retain_days}),
                ),
                Ok(_) => {}
                Err(e) => queue::log_event(
                    "audit",
                    serde_json::json!({"event":"prune-error","error":e}),
                ),
            }
            std::thread::sleep(std::time::Duration::from_secs(86_400));
        });
    }

    if let Err(e) = axum::serve(listener, build_router())
        .with_graceful_shutdown(shutdown_signal())
        .await
    {
        eprintln!("org-relay: server error: {e}");
        std::process::exit(1);
    }
}
