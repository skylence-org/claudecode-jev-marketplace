# aw-context (herdr plugin)

Gives LLM agents running in [herdr](https://herdr.dev) panes accurate, on-demand
context about what the human is actually doing at the desktop, sourced from a
local [ActivityWatch](https://activitywatch.net) server. Pull-only: agents ask,
nothing is ever pushed into a pane.

Not a Claude Code plugin: this is a **herdr** plugin, installed with herdr's own
plugin manager. It is runtime-agnostic — any agent that can run a shell command
can use it.

## What the agent gets

The bundled `awctx` CLI (POSIX sh, needs `curl` + `jq`):

```
awctx now                        current app + window title + presence
awctx recent [minutes=30]        window history, chronological, with durations
awctx summary [hours=6]          active time per app + top windows (afk-filtered)
awctx afk [hours=3]              presence timeline (afk / not-afk spans)
awctx buckets                    available data buckets + freshness
awctx events <bucket> [min] [n]  raw events JSON from any bucket
awctx query '<program>' [hours]  raw aw-server query-language passthrough
awctx doctor                     check server, watchers, freshness
awctx agent-help                 this list, as a tool card for the agent

awctx categories                 category tree (name path + rule regex)
awctx category add <Path> <re> [--ignore-case]    add or update a rule
awctx category rm <Path>         remove one category entry
awctx category sync <file> [--replace]    upsert a category set / replace tree
awctx setting <key> [<json>]     read or write any aw-server setting
awctx bootstrap export [file]    capture tree + portable settings as a baseline
awctx bootstrap apply <file>     bring a fresh instance to that exact state
```

Accuracy notes:

- `summary` runs through the aw-server query engine with the same
  `flood` + `filter_keyvals(not-afk)` + `filter_period_intersect` pipeline the
  ActivityWatch dashboard uses, so an agent's numbers match what the human sees
  in their own UI.
- `now` and `doctor` report data age; watcher heartbeats lagging more than
  ~60s mean "current" answers are stale, and `doctor` says so.
- Buckets are discovered by type (`currentwindow`, `afkstatus`), not by
  hostname, so the scripts survive machine renames.

Write side: the category tree and all other aw-server settings are plain
REST state (`/api/0/settings/<key>`; categories live under `classes`), so
`category add/rm` and `setting` change what the human's own dashboard shows.
Every classes write first snapshots the previous tree into the plugin config
dir (`.../skylence.aw-context/backups/classes-<utc>-<pid>.json`); restore is
`awctx setting classes "$(cat <backup>)"`. `category add` upserts by exact
name path; nested paths use `/` (e.g. `Work/Agents`).

For identical categorization across machines, `category sync` brings the tree
to a known state from a JSON file: default mode upserts the file's entries and
leaves everything else alone, `--replace` makes the tree exactly the file.
No-op syncs skip the write, so setup scripts can run it every time.
`presets/agent-org.json` ships a starter set (`Work/Agents` + per-runtime
subcategories) used by the herdr-setup playbook:

```bash
awctx category sync /abs/path/to/herdr-plugins/aw-context/presets/agent-org.json
```

For a whole fresh instance (a new device), `bootstrap` captures and replays
the full desired state: the category tree plus the portable settings keys
(`startOfDay`, `startOfWeek`, `durationDefault`, `theme`, `views` — the
device-specific keys like `landingpage` and telemetry timestamps are
excluded). `presets/aw-baseline.json` is the committed reference, exported
2026-07-31; re-export and commit whenever the desired config changes.

```bash
awctx bootstrap export presets/aw-baseline.json   # on the reference machine
awctx bootstrap apply  presets/aw-baseline.json   # on every other device
```

## Install

```bash
herdr plugin install skylence-org/multi-llm-marketplace/herdr-plugins/aw-context
# or, for local development against this checkout:
herdr plugin link /abs/path/to/multi-llm-marketplace/herdr-plugins/aw-context
```

Requires herdr >= 0.7.4, `jq` on PATH, and a running ActivityWatch (aw-server
with aw-watcher-window + aw-watcher-afk). Non-default server: set
`AWCTX_SERVER` (default `http://127.0.0.1:5600`). Verify with:

```bash
herdr plugin action invoke doctor --plugin skylence.aw-context
herdr plugin log list   # action output lands here (stdout/stderr per run)
```

## Wiring it into agents

Actions (`doctor`, `now`, `summary`) work from herdr's action surface, but the
full CLI is the intended agent interface. Put `awctx` on PATH once:

```bash
ln -s /abs/path/to/herdr-plugins/aw-context/awctx ~/.local/bin/awctx
```

then add one line to the agent's instructions (CLAUDE.md, AGENTS.md, a
dispatch brief, ...):

> Run `awctx agent-help` for tools that report the human operator's live
> desktop activity (current window, presence, per-app time). Check
> `awctx doctor` before trusting the numbers.

## Privacy

Window titles routinely contain sensitive text (mail subjects, document names,
private URLs). Installing this plugin deliberately grants every agent with
shell access on this machine read access to that stream — it is the point of
the plugin, but decide that consciously. Scope: local aw-server only; nothing
leaves the machine unless an agent quotes it.

## Test

```bash
sh test/smoke.sh   # offline assertions always; live assertions when aw-server answers
```

## Limitations

- Writes cover settings/categories only. It does not record herdr/agent
  activity into ActivityWatch; a reverse `aw-watcher-herdr` (pane
  agent-status → AW bucket via `[[events]]`) would be a natural follow-up.
- One machine: it reads the local aw-server; remote/synced AW instances need
  `AWCTX_SERVER` pointed at them explicitly.
- `summary` needs both watcher buckets; a machine without aw-watcher-afk gets
  raw `recent`/`events` but no afk-filtered totals.
