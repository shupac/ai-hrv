# Cloud sync and MCP access

Status: Draft · Owner: Shu · Last updated: YYYY-MM-DD

## Goal
> In 2–3 sentences: what do you want to be able to do that you can't today?
> Who asks the questions, from where (phone? desktop?), and how fresh must the data be?

## Non-goals
> What this deliberately does NOT do. (e.g. replace local storage? multi-user?
> real-time under 1 min?) Non-goals stop scope creep — for you and for agents.

## Background
> What exists today, briefly: how data is stored now (link to DayStore.swift),
> data volume per day, relevant constraints (signing team, iOS background limits).
> Only what a reader needs to understand the decisions below.

## Decisions

### 1. Sync, not migrate
- **Decision:**
- **Why:**
- **Alternatives considered:**
- **Consequences:** > What does this cost or commit you to?

### 2. What is stored in the cloud (minute rows, raw chunks, tags)
- **Decision:**
- **Why:** > Why aren't minute rows enough on their own? Why chunks rather than one row per beat?
- **Alternatives considered:**
- **Consequences:**

### 3. Where HRV is computed
- **Decision:**
- **Why:**
- **Alternatives considered:**
- **Consequences:**

### 4. Motion and posture context (Polar H10)
- **Decision:**
- **Why:** > What did you observe about movement vs. psychological stress?
- **Alternatives considered:** > phone motion, Apple Watch
- **Consequences:** > What can and can't the accelerometer tell you?

### 5. Backend
- **Decision:**
- **Why:**
- **Alternatives considered:**
- **Consequences:** > cost, lock-in, storage limits

### 6. MCP server: remote vs. local, and tool design
- **Decision:**
- **Why:**
- **Alternatives considered:** > e.g. chat inside the app
- **Consequences:**

## Data model (sketch)
> Tables or objects and their key fields. Rough is fine; details come in the spec.

## MCP tools (sketch)
> Name, one-line purpose, and what each returns. Every response includes data freshness.

## Privacy and security
> Where does health data go? Who can access it, and how (auth)?
> What happens in the cloud when you delete a day in the app? Are any tags sensitive?

## Open questions
> Things not yet decided. Each with what would settle it.

## Milestones
> Ordered, each independently testable. Mark which ones need the H10.

## Decision log
| Date | Change | Reason |
|------|--------|--------|
