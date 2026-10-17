# Replay simulator

Status: Draft for review · Owner: Shu · Linear: TEM-5 (design), TEM-6 (build), TEM-7 (fixtures), TEM-14 (motion) · Last updated: 2026-10-17

## Goal

Run the whole app in the iOS simulator from a recorded or synthetic day instead of a strap: Live tab, chart,
tags, change prompts, notifications and the Live Activity, at real speed or faster. Agents can then check
their own changes end to end, and test days double as fixtures for the MCP evals later.

## Non-goals

- Simulating CoreBluetooth itself (scanning, pairing, state restoration). `HeartRateManager` stays as it is and
  is still tested on the phone.
- Background behaviour. A suspended simulator app runs no timers, so background delivery, Live Activity updates
  from the background and swipe-away stay phone tests.
- Network faults. Nothing in the app uses the network yet (see Decision 4).

## Background: how data flows today

- `HeartRateManager` (`HRV/BLE/HeartRateManager.swift`) parses each 0x2A37 notification and calls
  `onMeasurement(m, now)` with `now = Date()` at arrival (`:237-239`). Disconnects and Bluetooth power-off call
  `onDisconnect` (`:154`, `:205`).
- `AppModel` (`HRV/HRVApp.swift:14-24`) wires that into `LiveSession.handle(_:at:)`, starts and updates the Live
  Activity, and calls `LiveSession.handleDisconnect()` and `activity.end()` on disconnect.
- `LiveSession` (`HRV/Core/LiveSession.swift`) runs everything on the packet time `now`: `BeatProcessor` back-fills
  beat times from it (`HRV/Core/Beat.swift:29-53`), the 5 s tick, chart, `ChangeDetector` and buffer trim are
  driven by packets, not timers (`LiveSession.swift:60-66`). Beats go to `DayStore.append` (`:56`).
- `ChangeDetector` (`HRV/Core/ChangeDetector.swift`) is a pure function of the timestamps it's given.
- `ChangePrompter` (`HRV/Notifications/ChangePrompter.swift`) is not: it checks quiet hours with `Date()` (`:39`)
  and queries iPhone motion over a wall-clock range (`:56-70`).
- `DayStore` (`HRV/Storage/DayStore.swift`) already takes `root:` (`:66`), which the tests use
  (`HRVTests/HRVTests.swift:154`, `:195`). The day file is chosen by the beat's time (`:83`).
- The UI reads `model.ble` directly for `state`, `deviceName`, `battery`, `lastPacket` and the device list
  (`HRV/UI/LiveView.swift:39-52`, `HRV/UI/StrapView.swift`, `HRV/HRVApp.swift:39`, `:130-138`).

So the pipeline below `onMeasurement` is already almost clock-free. The work is a seam above it and a few
`Date()` calls that mean "pipeline time".

## Decisions

### 1. The seam: a `StrapSource` that emits one event stream

- **Decision:** Add a small protocol that `HeartRateManager` and a new `ReplaySource` both implement, with all
  data streams going through one enum:

  ```swift
  enum StrapEvent {
      case heartRate(HeartRateMeasurement)
      case disconnected
      // TEM-9 adds: case motion([MotionSample])   // samples carry absolute Dates
  }

  protocol StrapSource: AnyObject, Observable {
      var state: StrapState { get }        // today's HeartRateManager.State, moved out and renamed
      var deviceName: String? { get }
      var battery: Int? { get }
      var lastPacket: Date? { get }
      /// The time the pipeline should treat as now: Date() for BLE, the replay position for replay.
      var now: Date { get }
      var onEvent: ((StrapEvent, Date) -> Void)? { get set }
  }
  ```

  `AppModel` holds `let strap: any StrapSource` and switches over `StrapEvent` in one place, replacing the two
  closures at `HRVApp.swift:14-24`. Scanning, connecting and forgetting stay on `HeartRateManager` only; the Strap
  tab shows those controls when `strap is HeartRateManager` and replay controls otherwise.
- **Why:** Replay then goes through exactly the code the strap uses, from `AppModel` down. A single event enum
  is what leaves room for motion: TEM-9 adds a case, the compiler forces `AppModel` (and `ReplaySource`) to
  handle it, and both streams come from one source with one clock, so they can't drift apart in replay.
- **Requirement on TEM-9:** at the seam, motion samples carry absolute `Date`s (sensor ticks mapped to wall
  clock inside the BLE layer). Then replay can reproduce them from a file by timestamp, like beats. If TEM-9 lands
  first with its own `onMotion` closure, TEM-6 folds it into the enum; no other change is needed.
- **Alternatives considered:**
  - *Replay calls `LiveSession.handle` directly.* Skips `AppModel` wiring, the Live Activity and `state`-driven
    UI, which are the parts most worth seeing in the simulator.
  - *Fake CoreBluetooth (feed raw 0x2A37 bytes into `HeartRateManager`).* Would also cover the parser, but needs a
    `CBPeripheral` stand-in and the parser already has unit tests.
  - *One closure per stream (`onMeasurement`, `onMotion`, …).* Works, but each new stream is a new property on
    every source and nothing forces replay to handle it.
- **Consequences:** a mechanical refactor of `AppModel` and the views that read `model.ble`. `HeartRateManager`'s
  behaviour must not change (TEM-6 "done when"); the user checks one connect/disconnect on the phone after it.

### 2. Starting a replay: launch arguments, Debug builds, simulator only

- **Decision:** Replay starts only from launch arguments, read through `UserDefaults` (the argument domain), e.g.

  ```sh
  xcrun simctl launch booted com.shu.hrvmonitor \
    -replay fixture:drop -replaySpeed 60 -replayEvents "disconnect 14:00 20m"
  ```

  `-replay` takes `fixture:<name>` (a generated day, Decision 6) or `file:<name>.csv`, read from
  `Documents/replay-input/` in the app container. A small `tools/replay.sh` copies a CSV there
  (`xcrun simctl get_app_container booted com.shu.hrvmonitor data`) and launches. Replay code is compiled under
  `#if DEBUG`, and `AppModel` only builds a `ReplaySource` when the argument is present and
  `targetEnvironment(simulator)`. Otherwise it builds `HeartRateManager` as today.
  In replay mode `HeartRateManager` is never constructed.
- **Why:** launch arguments are scriptable by agents and reproducible from a single command, and nothing persists:
  a normal launch is a normal app. The simulator-only check matters because the phone runs Debug builds too
  (README, "Build and install"). Not constructing `HeartRateManager` means no `CBCentralManager`, so no state
  restoration and no real strap data can reach the replay store.
- **Alternatives considered:** *a debug menu in the app.* Handy for a person, useless for agents, and needs UI
  and copy. Not needed for TEM-6. Once replay runs, the Strap tab gets minimal controls (Decision 4), which
  covers most of what a menu would.
- **Consequences:** no replay on the phone for now, so the real Lock Screen Live Activity can't be driven by
  replay. See open question 1.

### 3. Time: keep the recorded timestamps, add a virtual clock

- **Decision:** Replay emits each event with its **original recorded time**, not shifted to today. The
  `ReplaySource.now` is the replay position. The few places that mean "pipeline now" read `model.strap.now`
  instead of `Date()`:
  - manual tag time (`LiveView.swift:65`, `HRVApp.swift:52-54`),
  - quiet hours in `ChangePrompter.handle` (`ChangePrompter.swift:39`): pass `now` in with the event,
  - the movement check (`ChangePrompter.swift:37`, `:56-70`) becomes an injected function. BLE mode keeps the
    `CMMotionActivityManager` query; replay mode answers "not moving" (and replayed H10 motion later, TEM-13/14).

  Left on wall clock, on purpose: Live Activity throttling and `updated`/stale date
  (`LiveActivityController.swift:30-37`, `HRVApp.swift:49`), because they are about what the user sees now;
  `DayStore` flush timing (`DayStore.swift:88`); `StrapView` "last packet … ago".
- **Why:** with original timestamps the replayed day lands under its own date in the replay store, quiet hours
  behave as they did that day, and the output CSV can be compared with the input. Shifting to "now" would push
  time into the future at any speed above 1×, move the day key, and make quiet-hour behaviour depend on when you
  press Run.
- **How each part behaves faster than real time:**
  - *HRV, chart, change detection:* identical at any speed, since they only see packet times. Cooldowns (10 min
    snooze, 45 min `ChangePrompter.cooldown`) are in packet time, so a 45 min cooldown takes 45 s at 60×.
  - *Prompt timing race:* `LiveSession.detect` applies the 45 min snooze after `onChange` returns in a `Task`
    (`LiveSession.swift:88-92`). The immediate 10 min snooze (`:87`) covers it, and 10 min at 60× is 10 s, far
    longer than the prompt takes. At very high speeds that may stop holding, which is one reason to cap UI
    replay speed (Decision 4).
  - *Notifications:* delivered immediately in wall time. The simulator shows them, including the reply actions.
  - *Live Activity:* starts as today on the first packet in the foreground (`HRVApp.swift:17`). Updates are
    throttled to one per 10 s of wall time, which at 60× is one per 10 replay minutes. That's what ActivityKit
    allows anyway.
  - *Background:* when the simulator suspends the app, the replay timer stops and replay time pauses with it.
    No catch-up burst on resume.
- **Packets from beats:** the CSV stores beats, not packets (`DayStore.swift:82-89`). Replay groups beats into
  one packet per second of recorded time, with the packet time at the last beat in it. `BeatProcessor` then
  places the beats back where they were, within CSV rounding. Seconds without a beat get a packet with `bpm` and
  no RR, like a strap at low heart rate. Contact is sent as `true`, because the CSV doesn't record contact. The
  `valid` column is ignored and recomputed by `ArtifactFilter`. A `gap` row becomes a `.disconnected` event
  followed by state `.reconnecting` until the next beat.
- **Alternatives considered:** *inject a `Clock` into every component.* More general, but `LiveSession` and
  `ChangeDetector` already take time as a parameter. Only the four call sites above need it.

### 4. Speed, controls and scripted events

- **Decision:**
  - Speed is any number via `-replaySpeed` (default 1). The UI replay is tested up to 60× (a day in 24 min).
    Tests don't use speed at all (Decision 6).
  - In replay mode the Strap tab shows the source name, replay time, a pause/play button and a 1× / 10× / 60×
    picker. No explanatory text. The tab label stays "Strap". `state` follows the replay: `.connected` while
    playing, `.reconnecting` in a gap, `.idle` at the end.
  - Scripted events come from `-replayEvents`, a comma-separated list of `<kind> <HH:mm> <duration>` in the
    replayed day's local time:
    - `disconnect 14:00 20m`: no packets for the span. Emits `.disconnected` and is written as a gap, the same
      as a real dropout.
    - `noRR 09:30 1m`: packets with `bpm` but no RR, for the "Strap doesn't send RR intervals" warning
      (`LiveSession.swift:42-52`).
    - `contactLost 10:00 30s`: packets with contact `false`.
    - `seek 08:00`: start from this time instead of the first beat.

    An unknown kind stops the launch with an error, so a typo doesn't silently replay something else.
- **No network event yet:** nothing in the app talks to the network. When sync is built, network faults
  belong in a fake transport in the sync uploader, not in the strap source. The script grammar can grow a
  `network` kind then.
- **Why:** scripted events in the launch line make every scenario reproducible from one command, which is
  what an agent needs. A string beats a JSON file because it's one less file to copy into the container.

### 5. Isolation: a separate, wiped store

- **Decision:** In replay mode `AppModel` builds `DayStore(root: Documents/replay/)` (so its files are in
  `Documents/replay/days/`) and wipes that folder at each replay start. `LiveSession` and `ChangePrompter` get
  this store, so replayed beats, tags, change-prompt tags, notification answers and summaries all go there. The
  real `Documents/days/` is never opened.
- **Why:** `DayStore` already supports a root (`DayStore.swift:66`). Wiping on start keeps runs deterministic:
  `LiveSession.restoreRecent` (`LiveSession.swift:101-111`) restores nothing, and there are no leftovers from the
  last run. Not constructing `HeartRateManager` (Decision 2) closes the other direction.
- **Cross-mode notifications:** a replay notification answered after a normal launch finds no tag with that ID
  and is ignored (`DayStore.swift:196-200`). That's correct and needs no extra code.
- **Alternatives considered:** *in-memory store.* Loses the History tab and the output CSV for comparison.
  *A flag on rows.* Mixes data in the files the AGENTS.md rules protect.

### 6. Fixtures: generated days with known answers

- **Decision:** A `FixtureDay` builder in the app target under `#if DEBUG` (`HRV/Replay/FixtureDay.swift`),
  so both the tests and `-replay fixture:<name>` use it. It produces `[Beat]` (and CSV text) from segments:

  ```swift
  FixtureDay(start: "07:00")
      .steady(minutes: 60, hr: 60, rmssd: 40)
      .steady(minutes: 5, hr: 72, rmssd: 20)      // sustained drop → one prompt
      .artifacts(every: 50)                       // a missed beat (2× RR) every 50 beats
      .disconnect(minutes: 20)
  ```

  RR alternates `mean ± d/2`, so every successive difference is `d` and RMSSD is exactly `d`. Results can then be
  asserted exactly, not with tolerances. Jitter, if wanted, uses a seeded generator. Named fixtures for TEM-7:
  `rest`, `drop`, `rise`, `artifacts`, `disconnect`, `noRR`.

  Replay splits into a pure `ReplayTimeline` (beats + script → ordered `[(Date, StrapEvent)]`) and a thin
  timer driver. Tests feed the timeline straight into the `AppModel` wiring, synchronously and at full speed,
  then assert on `LiveSession`, the replay `DayStore` and the events passed to `onChange`.
- **Why:** recorded data can't be committed (AGENTS.md), and generated days with an exact RMSSD make failures
  easy to read. The same fixtures are planned as the base for the MCP evals (TEM-7 notes).
- **Real-day check (local only, never committed):** replaying one of your own day CSVs should give an output
  CSV with the same RR values and beat times as the input. Times can be off by a few tens of ms over a day,
  because RR is stored to 0.1 ms and `BeatProcessor` sums them. Run it on a few real days once TEM-6 lands.
  `valid` may differ only where contact was lost.

### 7. Motion later (TEM-9, TEM-10, TEM-13, TEM-14)

- `StrapEvent.motion` (Decision 1) is the only seam change. `AppModel` routes it to whatever TEM-10/TEM-11 build.
- `ReplayTimeline` reads the TEM-10 motion file for the same day next to the CSV and merges both streams by
  timestamp, so they stay in sync at any speed. Scripted `disconnect` drops both. A day without a motion file
  replays as a strap without PMD.
- `FixtureDay` gains motion segments (`.lying`, `.walking(minutes:)`, `.postureChange`) for TEM-14's
  "walking doesn't cause a prompt" test.
- The injected movement check (Decision 3) is where TEM-13 plugs in H10 motion, with the iPhone motion query as
  the fallback.

## Build order (TEM-6, then TEM-7)

1. `StrapSource`/`StrapEvent` and the `AppModel` refactor, BLE only. No behaviour change; phone check below.
2. `strap.now` at the four call sites, and the injected movement check.
3. `ReplayTimeline` + `FixtureDay`, with unit tests (no UI).
4. `ReplaySource` driver, launch arguments, replay store, Strap tab controls, `tools/replay.sh`, README section.
5. TEM-7 end-to-end tests on the named fixtures.

**Check on phone after step 1:** connect the strap, lock the screen for 10 min, walk out of range and back.
Data keeps arriving, the gap shows in History, the Live Activity ends on disconnect and returns when you open
the app.

## Open questions for Shu

1. **Replay on the phone?** Simulator-only is the safe default (Decision 2). Allowing it on the phone would let
   you see the real Lock Screen Live Activity and Mac menu bar with replayed data, but while it runs, a real
   strap isn't recorded and a pending real notification answered then is lost. Worth it?
2. **Original timestamps vs. "today":** are you fine with replayed data showing up under its original date in
   History (Decision 3)? The alternative only makes sense if you want to watch a replayed day at the actual time
   of day it was recorded.
3. **Speed cap:** is 60× enough for UI replay, or do you want "as fast as possible" in the UI too?
4. **Strap tab controls:** pause and a speed picker, or no in-app controls at all and launch arguments only?
5. **Scripted events:** anything you've seen on the phone that should be scriptable from the start, e.g. strap
   battery dropping or Bluetooth turned off (today `.poweredOff` also calls `onDisconnect`,
   `HeartRateManager.swift:152-154`)?
6. **TEM-9 coordination:** OK to ask TEM-9 to send motion as absolute-timestamped samples through
   `StrapEvent.motion`, or should it land with its own closure first and be folded in by TEM-6?
