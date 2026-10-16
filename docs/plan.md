# Project plan

Last updated: 2026-10-16

## Goals

**Product:** get feedback on physiological and psychological stress, to decide how hard to push training and cognitive work, and to see the effects of sleep and habits. Ask an AI about it, including about what is happening right now, from any Claude client.

**Learning:** practise the skills for agentic-SWE and FDE roles: problem scoping, design tradeoffs, tool and MCP design, evals, agent-loop fundamentals, working with coding agents (harness engineering), security and privacy, and communicating decisions.

## Milestones

Each milestone should be done and verified before the next one starts, unless marked parallel.

| # | Milestone | Done when | Skill practised |
|---|-----------|-----------|-----------------|
| 1 | Agent context: `AGENTS.md`, `CLAUDE.md` | A fresh agent session can build, test and explain the constraints without being told | Context engineering |
| 2 | Design doc: `docs/cloud-sync.md` | Every decision has a why and alternatives; reviewed | Scoping, tradeoffs, writing |
| 3 | Replay simulator: a fake strap that replays recorded day CSVs | The app runs end to end in the simulator with real recorded data; tests use it | Verification loops |
| 4 | Schema and MCP tool spec | Tables, raw-chunk format and tool list written down and reviewed | API and tool design |
| 5 | Local Supabase + uploader in the app | Minute rows, raw chunks and tags reach the local DB within ~1 min; backfill of past days works; offline catch-up works | Isolated environments, sync design |
| 6 | MCP server (local first) | Claude Desktop/Code answers questions using `recent()`, `day_summary()`, `zoom()`, tags; responses state data freshness | MCP |
| 7 | Evals for the MCP tools | A question set with known answers from fixture data, scored automatically | Evals |
| 8 | Hosted backend + remote MCP with OAuth | Works from Claude on the phone; real data synced | Deployment, auth, privacy |
| 9 | H10 integration: RR + accelerometer | Posture (lying / upright / moving) and transitions in minute rows; accel in raw chunks | BLE protocols, signal processing |
| 10 | From-scratch HRV analyst agent | Own agent loop over the same tools passes the eval set; compared with Claude + MCP | Agent-loop fundamentals |

Guardrails (permissions, a test hook after edits) get added alongside milestones 1 and 3, as soon as there is something to enforce.

Optional, cheap: read Apple Watch step counts from HealthKit as motion context before the H10 work. Useful afterwards for looking back.

## Dependencies

- **H10** (ordered 2026-10-16) is deliberately integrated after the hosted backend (8): first see what data is actually useful, then decide what motion data to store. Milestones 5–8 design for RR only, with one cheap hedge: a version field in the raw-chunk format, so adding accelerometer data later is a new version rather than a breaking change. Expect a schema migration for posture columns in 9.
- Milestone 3 (replay) makes 5–7 testable without wearing the strap.
- Milestones 5 and 6 can run in parallel once 4 is done (separate worktrees).
- Milestone 10 can start any time after 6, since it reuses the same tools.

## Status

- **Done:** design discussion (decisions summarised in `docs/cloud-sync.md` once written).
- **In progress:** 1 and 2 (templates saved; Shu is writing them).
- **Next up:** 3.

## Retro notes

> After each milestone: what was decided, what alternatives were rejected, what broke or surprised you,
> where the agent struggled and what harness change fixed it. These double as interview stories.
