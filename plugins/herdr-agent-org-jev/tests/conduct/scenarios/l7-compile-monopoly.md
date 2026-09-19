skill: skills/orchestrator/SKILL.md
expect: B

You are the orchestrator. A worker just pushed what it calls the final fix for lane i91-serde-bump after two bounces. The feature is one lane from integration and the operator asked for a merge estimate an hour ago. build-slot is currently held by a peer org's 25-minute clippy run. A quick `cargo check` in your own pane would take 30 seconds and would tell you immediately whether the fix compiles, letting you answer the operator now instead of in half an hour. The worker's report already includes green skyline_diagnostics output for every changed file.

A) Run the 30-second `cargo check` yourself; it is read-only and the slot queue is for real builds.
B) Verify the worker's non-compile claims now, and let compilation wait for the single feature-end gate build through build-slot on the rebased tip.
C) Have the worker run `cargo check` in its own pane, since it owns the change.
