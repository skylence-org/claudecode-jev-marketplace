//! The rmcp server surface: per-session `RelayServer` (guide gate state),
//! ServerHandler impl (instructions, relay://guide resource, tool dispatch),
//! and SEP-2663 task wiring. Transport is rmcp streamable HTTP behind axum
//! (see main.rs), the same stack binary-skyline ships.
//!
//! Guide gate and transport statefulness: rmcp keeps ONE RelayServer per
//! session only for the legacy lifecycle (protocol < 2026-07-28, client
//! echoes Mcp-Session-Id). SEP-2567 (2026-07-28) removed sessions; rmcp then
//! serves every POST statelessly through a FRESH RelayServer from the
//! factory, so a per-session "guide read" flag can never be observed set and
//! the gate would refuse forever (field-reproduced 2026-08-17: relay_guide ok,
//! then 5x "has not read relay://guide"). The gate therefore applies ONLY to
//! session-routed requests; a stateless client is trusted to follow the
//! server instructions and read the guide first.
//!
//! Wake plane in one paragraph: `relay_await` from a tasks-capable client
//! returns a task handle IMMEDIATELY (CreateTaskResult) and the hold runs as
//! a task; from any other client it holds in-call (Claude Code >= 2.1.212
//! auto-backgrounds the held call at ~2 min into a native background task).
//! Both paths run the same `queue::op_await` future, which registers the
//! recipient in the awaiter registry for its whole lifetime — that registry
//! is what the nudge watchdog and relay_status read.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

use rmcp::model::{
    CacheScope, CallToolRequestParams, CallToolResponse, CallToolResult, CancelTaskParams,
    ContentBlock, CreateTaskResult, GetTaskParams, GetTaskResult, Implementation,
    ListResourcesResult, ListToolsResult, PaginatedRequestParams, ProgressNotificationParam,
    ReadResourceRequestParams, ReadResourceResponse, ReadResourceResult, Resource,
    ResourceContents, ServerCapabilities,
    ServerInfo, Tool, UpdateTaskParams,
};
use rmcp::service::RequestContext;
use rmcp::task_manager::{TaskExit, TaskManager, TaskOptions};
use rmcp::transport::common::http_header::HEADER_SESSION_ID;
use rmcp::{ErrorData, RoleServer, ServerHandler};
use serde_json::{json, Value};

use crate::guide::{guide_hash, GUIDE_GATE_REFUSAL, GUIDE_RESOURCE, GUIDE_URI, SERVER_INSTRUCTIONS};
use crate::queue::{self, TaskCoverGuard, AWAIT_MAX_S};

/// Tools that refuse until the session has read relay://guide. The guide is
/// the wake-plane contract; status/observability tools stay ungated so a
/// health probe never needs a guide read.
const GATED_TOOLS: &[&str] = &["relay_send", "relay_inbox", "relay_consume", "relay_await"];

/// Process-global task manager: tasks/get must resolve a task id no matter
/// which HTTP session polls it, and the awaiter registry it feeds is global.
fn tasks() -> &'static TaskManager {
    static T: OnceLock<TaskManager> = OnceLock::new();
    T.get_or_init(TaskManager::new)
}

pub struct RelayServer {
    /// GUIDE-GATE condition: set once relay://guide has been read this
    /// session (resource read or relay_guide tool). One RelayServer exists
    /// per HTTP session (LocalSessionManager builds them via the closure in
    /// main.rs) — and one per REQUEST on the stateless path, where this flag
    /// is meaningless and the gate is skipped (see module doc).
    guide_read: AtomicBool,
}

/// Whether the request rides an rmcp session: the transport injects the
/// http request Parts into extensions, and session-routed requests always
/// carry Mcp-Session-Id (a legacy-lifecycle request without it is rejected
/// before dispatch unless it is `initialize`). Stateless SEP-2567 requests
/// never carry it.
fn extensions_carry_session(ext: &rmcp::model::Extensions) -> bool {
    ext.get::<axum::http::request::Parts>()
        .is_some_and(|p| p.headers.contains_key(HEADER_SESSION_ID))
}

impl RelayServer {
    pub fn new() -> Self {
        RelayServer { guide_read: AtomicBool::new(false) }
    }

    fn on_guide_read(&self) {
        self.guide_read.store(true, Ordering::Relaxed);
    }

    /// Refusal for gated tools while the guide is unread. Stateless: an
    /// identical retry after the read succeeds. `sessionful` false means the
    /// request has no session to remember a read in, so no gate applies.
    fn guide_gate(&self, tool: &str, sessionful: bool) -> Option<CallToolResult> {
        if sessionful && GATED_TOOLS.contains(&tool) && !self.guide_read.load(Ordering::Relaxed) {
            return Some(CallToolResult::error(vec![ContentBlock::text(GUIDE_GATE_REFUSAL)]));
        }
        None
    }
}

fn ok_result(v: Value) -> CallToolResult {
    let mut r = CallToolResult::success(vec![ContentBlock::text(v.to_string())]);
    r.structured_content = Some(v);
    r
}

fn err_result(e: String) -> CallToolResult {
    CallToolResult::error(vec![ContentBlock::text(e)])
}

/// One access-stream record per tool call (off by default, same as 0.5.x).
fn log_access(name: &str, args: &Value, started: std::time::Instant, out: &CallToolResult) {
    if !queue::stream_enabled("access") {
        return;
    }
    let is_err = out.is_error.unwrap_or(false);
    let bytes: usize = out
        .content
        .iter()
        .filter_map(|c| c.as_text().map(|t| t.text.len()))
        .sum();
    queue::log_event(
        "access",
        json!({"tool": name, "status": if is_err {"error"} else {"ok"},
            "duration_ms": started.elapsed().as_millis() as u64, "result_bytes": bytes,
            "agent": args.get("agent").or_else(|| args.get("sender")).cloned()}),
    );
}

fn tool_defs() -> Value {
    let s = |d: &str| json!({"type": "string", "description": d});
    // outputSchema (SEP-2106) mirrors what dispatch actually returns per
    // tool; results also arrive as structuredContent so consumers never
    // string-parse the text block.
    let msg_schema = json!({"type": "object", "properties": {
        "id": {"type": "integer"}, "ts": {"type": "string"},
        "sender": {"type": "string"}, "recipient": {"type": "string"},
        "lane": {"type": ["string", "null"]}, "kind": {"type": "string"},
        "body": {"type": "string"}, "consumed_at": {"type": ["string", "null"]}}});
    let inbox_out = json!({"type": "object", "properties": {
        "agent": {"type": "string"}, "count": {"type": "integer"},
        "messages": {"type": "array", "items": msg_schema},
        "timed_out": {"type": "boolean"}, "note": {"type": "string"}}});
    json!([
        {"name": "relay_guide",
         "description": "The relay guide (same text as resource relay://guide). Reading it unlocks the messaging tools for this session: the guide is the wake-plane contract (task-backed awaiting, arm-as-last-call, inbox-first turn entry, consume-after-acting).",
         "inputSchema": {"type": "object", "properties": {}},
         "outputSchema": {"type": "object", "properties": {
             "guide": {"type": "string"}, "guide_hash": {"type": "string"}}}},
        {"name": "relay_send",
         "description": "Queue a durable message for another org agent (replaces doorbell/ring). Enqueue is not delivery: the recipient's relay_await (in-call or task-backed) or the nudge net turns it into a read. A live awaiter wakes in-process the moment this returns.",
         "inputSchema": {"type": "object", "required": ["sender", "to", "kind", "body"], "properties": {
             "sender": s("your agent name"),
             "to": s("recipient agent name (e.g. orch-<feature>)"),
             "lane": s("optional lane/todo slug for context"),
             "kind": s("doorbell | ring | blocker | incident | peer | operator | other"),
             "body": s("the message; stored verbatim, no shell interpolation hazards")}},
         "outputSchema": {"type": "object", "properties": {
             "id": {"type": "integer"}, "queued_for": {"type": "string"}}}},
        {"name": "relay_inbox",
         "description": "List messages queued for an agent (unconsumed only unless include_consumed). The first bus action of any turn entered while lanes are in flight.",
         "inputSchema": {"type": "object", "required": ["agent"], "properties": {
             "agent": s("agent name"),
             "include_consumed": {"type": "boolean", "description": "default false"}}},
         "outputSchema": inbox_out},
        {"name": "relay_consume",
         "description": "Mark handled message ids consumed, AFTER acting on them. Explicit on purpose: a crash between reading and acting loses nothing.",
         "inputSchema": {"type": "object", "required": ["agent", "ids"], "properties": {
             "agent": s("agent name"),
             "ids": {"type": "array", "items": {"type": "integer"}, "description": "message ids from inbox/await"}}},
         "outputSchema": {"type": "object", "properties": {
             "consumed": {"type": "integer"}, "of": {"type": "integer"}}}},
        {"name": "relay_await",
         "description": "Task-backed coverage: wait until a message arrives for agent, then return the unconsumed inbox. Arm ONE await with a LONG timeout as the LAST call of a turn. Clients declaring the MCP tasks extension (io.modelcontextprotocol/tasks) get a task handle back immediately and poll tasks/get; other clients hold the call open (Claude Code >= 2.1.212 auto-backgrounds the held call at ~2 minutes into a native background task, freeing the turn — the result arrives as a task notification). timeout_s default 1800, max 3600; a timeout returns cleanly with retry:true — re-arm one new await, never a tight loop.",
         "inputSchema": {"type": "object", "required": ["agent"], "properties": {
             "agent": s("agent name"),
             "timeout_s": {"type": "integer", "description": "1..3600, default 1800; one long await per idle period"}}},
         "outputSchema": inbox_out},
        {"name": "relay_audit_tail",
         "description": "Last N events from an observability stream. audit = message lifecycle (send / await_start / await_wake with waited_ms and oldest_msg_age_ms / await_timeout / consume). access = one record per MCP tool call. nudge = one record per watchdog turn-starter ring (recipient, outcome, backlog age).",
         "inputSchema": {"type": "object", "properties": {
             "stream": s("audit (default) | access | nudge"),
             "limit": {"type": "integer", "description": "1..1000, default 50"}}},
         "outputSchema": {"type": "object", "properties": {
             "stream": {"type": "string"}, "enabled": {"type": "boolean"},
             "count": {"type": "integer"}, "events": {"type": "array", "items": {"type": "object"}}}}},
        {"name": "relay_observability_set",
         "description": "Turn a stream on or off at runtime; persists to relay-observability.json next to the db. An ORG_RELAY_AUDIT / ORG_RELAY_ACCESS / ORG_RELAY_NUDGE env var overrides the file. Defaults: audit ON, access OFF, nudge ON.",
         "inputSchema": {"type": "object", "required": ["stream", "enabled"], "properties": {
             "stream": s("audit | access | nudge"),
             "enabled": {"type": "boolean", "description": "true to record, false to stop"}}},
         "outputSchema": {"type": "object", "properties": {
             "stream": {"type": "string"}, "enabled": {"type": "boolean"}, "config": {"type": "string"}}}},
        {"name": "relay_observability_status",
         "description": "Per-stream enabled flag, log path, current size, plus rotation settings.",
         "inputSchema": {"type": "object", "properties": {}},
         "outputSchema": {"type": "object", "properties": {
             "audit": {"type": "object"}, "access": {"type": "object"},
             "max_log_bytes": {"type": "integer"}}}},
        {"name": "relay_status",
         "description": "Unconsumed message counts per recipient, the db path, which recipients currently hold live await coverage in this daemon (awaiting; in-call and task-backed holds both count), and the nudge watchdog state. Non-empty queues with an empty awaiting list is the deaf-org shape the nudge watchdog exists for. Never guide-gated.",
         "inputSchema": {"type": "object", "properties": {}},
         "outputSchema": {"type": "object", "properties": {
             "db": {"type": "string"},
             "queues": {"type": "array", "items": {"type": "object", "properties": {
                 "recipient": {"type": "string"}, "unconsumed": {"type": "integer"}}}},
             "awaiting": {"type": "array", "items": {"type": "string"}},
             "nudge": {"type": "object", "properties": {
                 "enabled": {"type": "boolean"}, "helper": {"type": ["string", "null"]}}}}}}
    ])
}

pub fn build_tools() -> Vec<Tool> {
    serde_json::from_value(tool_defs()).expect("tool_defs must deserialize into Vec<Tool>")
}

impl ServerHandler for RelayServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(
            ServerCapabilities::builder()
                .enable_tools()
                .enable_resources()
                .enable_tasks()
                .build(),
        )
        .with_server_info(Implementation::new("org-relay", env!("CARGO_PKG_VERSION")))
        .with_instructions(SERVER_INSTRUCTIONS)
    }

    async fn list_resources(
        &self,
        _: Option<PaginatedRequestParams>,
        _: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, ErrorData> {
        let guide = Resource::new(GUIDE_URI, "org-relay guide")
            .with_title("org-relay guide")
            .with_description(
                "The wake-plane contract: task-backed awaiting, arm-as-last-call, \
                 inbox-first turn entry, consume-after-acting, the nudge net. \
                 Reading it unlocks the messaging tools for this session.",
            )
            .with_mime_type("text/markdown");
        Ok(ListResourcesResult::with_all_items(vec![guide])
            .with_ttl_ms(3_600_000)
            .with_cache_scope(CacheScope::Private))
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, ErrorData> {
        if request.uri == GUIDE_URI {
            self.on_guide_read();
            Ok(ReadResourceResult::new(vec![ResourceContents::TextResourceContents {
                uri: GUIDE_URI.to_owned(),
                mime_type: Some("text/markdown".to_owned()),
                text: GUIDE_RESOURCE.to_owned(),
                meta: None,
            }])
            .with_ttl_ms(3_600_000)
            .with_cache_scope(CacheScope::Private)
            .into())
        } else {
            Err(ErrorData::resource_not_found(
                format!("unknown resource: {}", request.uri),
                None,
            ))
        }
    }

    async fn list_tools(
        &self,
        _: Option<PaginatedRequestParams>,
        _: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        Ok(ListToolsResult::with_all_items(build_tools())
            .with_ttl_ms(3_600_000)
            .with_cache_scope(CacheScope::Private))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let started = std::time::Instant::now();
        let name = request.name.to_string();
        let args: Value = request
            .arguments
            .map(Value::Object)
            .unwrap_or_else(|| json!({}));
        // Guide gate: strictly per-session and in-memory. No persisted ack —
        // the client token (clientInfo name/version) is shared by every
        // session of the same client build, so a durable ledger would let the
        // first reader of the day unlock the bus for sessions that never saw
        // the contract. A reconnect re-reads; the guide is short on purpose.
        // Stateless (SEP-2567) requests have no session: no gate (module doc).
        let sessionful = extensions_carry_session(&context.extensions);
        if let Some(refusal) = self.guide_gate(&name, sessionful) {
            log_access(&name, &args, started, &refusal);
            return Ok(refusal.into());
        }

        match name.as_str() {
            "relay_guide" => {
                self.on_guide_read();
                let out = ok_result(json!({"guide": GUIDE_RESOURCE, "guide_hash": guide_hash()}));
                log_access(&name, &args, started, &out);
                Ok(out.into())
            }
            "relay_await" => {
                let client_declared_tasks = context
                    .client_capabilities()
                    .is_some_and(|caps| caps.supports_tasks());
                if client_declared_tasks {
                    // SEP-2663 path: materialize the hold as a task and hand
                    // back the handle immediately. TTL covers the longest
                    // possible hold plus an hour of result retention.
                    let status = args
                        .get("agent")
                        .and_then(|v| v.as_str())
                        .map(|a| format!("awaiting relay messages for {a}"))
                        .unwrap_or_else(|| "awaiting relay messages".to_owned());
                    let task = tasks().spawn(
                        TaskOptions::new()
                            .with_ttl_ms((AWAIT_MAX_S + 3600) * 1000)
                            .with_poll_interval_ms(2_000)
                            .with_status_message(status),
                        move |ctx| {
                            Box::pin(async move {
                                // Coverage for a task-backed hold is the
                                // TaskCoverGuard, alive only while tasks/get
                                // polls arrive — a dead session's orphan task
                                // must not suppress the nudge (queue.rs).
                                let _cover = args
                                    .get("agent")
                                    .and_then(|v| v.as_str())
                                    .map(|a| TaskCoverGuard::new(ctx.task_id(), a));
                                tokio::select! {
                                    out = queue::op_await(&args, false) => match out {
                                        Ok(v) => Ok(ok_result(v)),
                                        Err(e) => Ok(err_result(e)),
                                    },
                                    _ = ctx.cancelled() => Err(TaskExit::Cancelled),
                                }
                            })
                        },
                    );
                    return Ok(CallToolResponse::Task(CreateTaskResult::new(task)));
                }
                // In-call hold: the client (or its harness) owns backgrounding.
                // PROGRESS KEEPALIVE (probe-measured 2026-08-05): Claude Code
                // idle-aborts a silent call at ~300s even after backgrounding
                // it — rmcp's SSE keepalives do not reset its idle timer, but
                // progress notifications do. Tick every 45s when the request
                // carries a progressToken; without one, the client-side
                // CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT export is the only
                // defense (bootstrap doctrine).
                let held = match context.meta.get_progress_token() {
                    Some(token) => {
                        let peer = context.peer.clone();
                        let hold = queue::op_await(&args, true);
                        tokio::pin!(hold);
                        // 20s cadence: resets the client's MCP idle timer well
                        // inside its 300s bound. NOT a liveness probe: rmcp's
                        // notification sink is fire-and-forget (`let _ =
                        // try_send`), so a dead client's sends never surface an
                        // error here — measured twice, 2026-08-05 (ghost
                        // smokes v1/v2: 45s and 20s cadences, 150s and 420s
                        // horizons, zero observable failures). Ghost holds are
                        // instead filtered OUT of coverage views by the
                        // watchdog's live-agent snapshot (queue.rs).
                        let mut tick =
                            tokio::time::interval(std::time::Duration::from_secs(20));
                        tick.tick().await; // discard the immediate first tick
                        let mut beats = 0f64;
                        loop {
                            tokio::select! {
                                out = &mut hold => break out,
                                _ = tick.tick() => {
                                    beats += 1.0;
                                    let _ = peer
                                        .notify_progress(ProgressNotificationParam::new(
                                            token.clone(),
                                            beats,
                                        ))
                                        .await;
                                }
                            }
                        }
                    }
                    None => queue::op_await(&args, true).await,
                };
                let out = match held {
                    Ok(v) => ok_result(v),
                    Err(e) => err_result(e),
                };
                log_access(&name, &args, started, &out);
                Ok(out.into())
            }
            _ => {
                let n = name.clone();
                let a = args.clone();
                let out = tokio::task::spawn_blocking(move || queue::op_sync(&n, &a))
                    .await
                    .map_err(|e| ErrorData::internal_error(format!("tool task failed: {e}"), None))?;
                let out = match out {
                    Ok(v) => ok_result(v),
                    Err(e) => err_result(e),
                };
                log_access(&name, &args, started, &out);
                Ok(out.into())
            }
        }
    }

    async fn get_task(
        &self,
        request: GetTaskParams,
        _: RequestContext<RoleServer>,
    ) -> Result<GetTaskResult, ErrorData> {
        // A poll is proof of life: it keeps the task's coverage entry fresh
        // so the nudge watchdog treats this recipient as listened-for.
        queue::touch_task_cover(&request.task_id);
        tasks().get_task(&request.task_id).map(GetTaskResult::new)
    }

    async fn update_task(
        &self,
        request: UpdateTaskParams,
        _: RequestContext<RoleServer>,
    ) -> Result<(), ErrorData> {
        tasks().update_task(&request.task_id, request.input_responses)
    }

    async fn cancel_task(
        &self,
        request: CancelTaskParams,
        _: RequestContext<RoleServer>,
    ) -> Result<(), ErrorData> {
        tasks().cancel_task(&request.task_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL_GATED: &[&str] = &["relay_send", "relay_inbox", "relay_consume", "relay_await"];
    const NEVER_GATED: &[&str] = &[
        "relay_guide",
        "relay_status",
        "relay_audit_tail",
        "relay_observability_set",
        "relay_observability_status",
    ];

    #[test]
    fn tool_defs_deserialize_into_rmcp_tools() {
        let tools = build_tools();
        assert_eq!(tools.len(), 9);
        assert!(tools.iter().any(|t| t.name == "relay_guide"));
    }

    fn parts_with_headers(headers: &[(&str, &str)]) -> axum::http::request::Parts {
        let mut b = axum::http::Request::builder();
        for (k, v) in headers {
            b = b.header(*k, *v);
        }
        b.body(()).unwrap().into_parts().0
    }

    #[test]
    fn session_detection_reads_mcp_session_id_from_injected_parts() {
        let mut with = rmcp::model::Extensions::new();
        with.insert(parts_with_headers(&[("mcp-session-id", "abc")]));
        assert!(extensions_carry_session(&with));

        let mut without = rmcp::model::Extensions::new();
        without.insert(parts_with_headers(&[("mcp-protocol-version", "2026-07-28")]));
        assert!(!extensions_carry_session(&without), "stateless request has no session");

        assert!(!extensions_carry_session(&rmcp::model::Extensions::new()), "no parts, no session");
    }

    #[test]
    fn guide_gate_refuses_each_messaging_tool_when_unread() {
        let srv = RelayServer::new();
        for tool in ALL_GATED {
            let r = srv.guide_gate(tool, true);
            assert!(r.is_some(), "guide_gate must refuse {tool}");
            assert_eq!(r.unwrap().is_error, Some(true));
        }
    }

    #[test]
    fn guide_gate_never_blocks_status_or_observability() {
        let srv = RelayServer::new();
        for tool in NEVER_GATED {
            assert!(srv.guide_gate(tool, true).is_none(), "{tool} must never be gated");
        }
    }

    #[test]
    fn guide_gate_opens_after_read_and_refusal_is_stateless() {
        let srv = RelayServer::new();
        assert!(srv.guide_gate("relay_send", true).is_some(), "first call unread");
        assert!(srv.guide_gate("relay_send", true).is_some(), "second call unread");
        srv.on_guide_read();
        for tool in ALL_GATED {
            assert!(srv.guide_gate(tool, true).is_none(), "gate must open for {tool}");
        }
    }

    #[test]
    fn guide_gate_skipped_for_stateless_requests() {
        // SEP-2567: a fresh RelayServer per request, guide never observed
        // read — the gate must not apply or it refuses forever.
        let srv = RelayServer::new();
        for tool in ALL_GATED {
            assert!(srv.guide_gate(tool, false).is_none(), "{tool} must pass without a session");
        }
    }

    #[test]
    fn refusal_text_pinned_verbatim() {
        assert_eq!(
            GUIDE_GATE_REFUSAL,
            "guide-gate: this session has not read relay://guide. Call relay_guide (or resources/read uri relay://guide; server name is usually `relay`), then retry this exact call. Why: the wake plane is task-backed now (ONE long relay_await armed as the LAST call of a turn — never a 50s re-arm loop), turn entry is inbox-first, and consume comes only after acting; using the bus without this contract re-creates the 3h23m deaf-org stall. (the gate is per-session and in-memory by design — every session, and every reconnect, reads the short guide once)",
            "GUIDE_GATE_REFUSAL drifted from pinned text"
        );
    }
}
