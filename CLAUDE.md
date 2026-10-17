@AGENTS.md

## Claude Code specific
> Shared instructions live in AGENTS.md (imported above), so Codex and Cursor see them too.
> Put only Claude Code–specific notes here, e.g. which skills or slash commands to use
> for this repo, or how to use subagents and worktrees. Hooks and permissions belong in
> .claude/settings.json, not here. If there's nothing Claude-specific, keep just the import line.

Parallel sessions (e.g. via `/plan-issue`) share the iPhone 17 Pro simulator. Only one should run tests at a time.
Give any other session its own simulator: `xcrun simctl create "iPhone 17 Pro B" "iPhone 17 Pro"`.
