# Cloud sync notes

Raw material for `docs/cloud-sync.md`, which Shu writes. These are the decisions and leanings from design
discussions with Claude, so they don't live only in Claude's memory. Agents: don't treat this as the spec, and
don't edit `cloud-sync.md`.

## From the 2026-10-16 discussion (nothing implemented)

**Sync, not migrate.** The local day CSVs stay the source of truth. The app uploads every 30–60 s while connected;
about 1 minute of latency is fine.

**Purpose.** Ask Claude what's happening right now, from the phone, and get longer-term feedback on stress,
training and cognitive load, sleep and habits.

**What goes to the cloud.**
- Minute rows in a database: mean, min and max HR, RMSSD over 60 s, artifact %, coverage, posture and movement.
- Raw beats, and later H10 accelerometer data at about 25 Hz, as compressed chunks of about 5 minutes. Minute rows
  answer most questions. Chunks let `zoom` go back to the raw signal without storing one row per beat.
- Tags, upserted by UUID.

**Where HRV is computed.** In the Swift app, which uploads the derived rows. The HRV math isn't ported to the
server, so there's one implementation of the artifact filter and RMSSD.

**MCP server.** Remote, with OAuth, so it works from Claude on the phone. Tools are shaped around analysis questions,
including `recent()` and `zoom(start, end)` over the raw chunks. Every response states how fresh the data is.

**Backend.** Supabase was the leading candidate. CloudKit was possible, since the app is signed with a paid
developer team, but was rejected: it's hard to query from an MCP server.

**Why motion is in scope.** Movement affects Shu's HRV more than psychological stress, so posture and movement
context is needed to tell the two apart. See `docs/plan.md`, "Sensors".

## Milestone order

The order lives in Linear (project AI-HRV): H10 motion and replay, then data and architecture design (starting with
a spike that asks Claude real stress questions on local data), then sync to a local backend, then a hosted backend,
then the MCP server.
