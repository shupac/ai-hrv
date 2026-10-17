# Project plan

Last updated: 2026-10-17

## Goals

**Product:** get feedback on physiological and psychological stress, to decide how hard to push training and cognitive work, and to see the effects of sleep and habits. Ask an AI about it, including about what is happening right now, from any Claude client.

**Learning:** practise the skills for agentic-SWE and FDE roles: problem scoping, design tradeoffs, tool and MCP design, evals, agent-loop fundamentals, working with coding agents (harness engineering), security and privacy, and communicating decisions.

## Sensors

- **Chest strap for RR intervals.** Apple Watch and Fitbit can't stream RR intervals, so a chest strap stays the
  sensor.
- **Polar H10 for motion.** Movement affects my HRV more than psychological stress, so the app needs posture and
  movement context to tell them apart. The phone usually sits on a desk, so its motion sensor says little about me.
  The H10's chest accelerometer does. Watch steps via HealthKit are a fallback when the H10 isn't worn.

## Tracking

Milestones, issues and status live in Linear: project AI-HRV, team Tempo
(https://linear.app/buildwithtempo/project/ai-hrv-599879a7dc57). This file keeps only the goals, the sensor choice and retro notes.

## Retro notes

> After each milestone: what was decided, what alternatives were rejected, what broke or surprised you,
> where the agent struggled and what harness change fixed it. These double as interview stories.
