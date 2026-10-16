# AGENTS.md

## Project

iOS app that records heart rate and RR intervals from a BLE chest strap all day and shows HRV,
to give feedback on physiological and psychological stress: how hard to push training and
cognitive work, and how sleep and habits affect recovery.
Planned: cloud sync and an MCP server so AI chatbots can analyse the data. See docs/plan.md for status.

## Commands

Build, test, and install commands: see README, "Build and install". Tests run on the iPhone 17 Pro simulator.

## How to verify a change

Tests must pass.
The simulator has no Bluetooth, so final testing is done by the user on an iPhone with a chest strap.
If a change touches BLE, background behaviour, the Live Activity or notifications, say what you
couldn't verify and list the exact steps for the user to check on the phone.

## Conventions

Don't explain features in the app itself. If copy is needed, keep it concise.

## Committing

The agent writes commit messages. Before each commit:

1. Review the full diff (`git diff --staged`) for mistakes and leftover debug code.
2. If the change alters setup, commands, user-visible behaviour or a number documented in the README,
   update the README and include it in the same commit. Same for docs/ files the change makes wrong.
3. Write the message: a short imperative subject line, then a body saying what changed and why,
   plus anything the user still has to verify on the phone.

One logical change per commit; split unrelated changes.

## Constraints

- Health data stays on the device, except for the chosen sync backend. No analytics or third-party SDKs.
  Don't log raw beat data. Never commit recorded data or secrets.
- No third-party dependencies: Apple frameworks only. Talk to web services with `URLSession`.
- Recording in the background depends on the `bluetooth-central` background mode. Swiping the app away
  stops it until the app is opened again. See README, "Background behaviour".

## Don't

- Change the day CSV format or `tags.json` without migrating existing files. Recorded history can't be recreated.
- Change artifact-filter or RMSSD thresholds without saying so explicitly; they define what every past value means.

## Where to look

- Current status and milestones: docs/plan.md
- Before working on sync: docs/cloud-sync.md
- Before touching HRV calculations: README, "How HRV is computed"
