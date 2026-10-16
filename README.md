# HRV

Minimal iPhone app: connects to a Bluetooth heart-rate chest strap (e.g. Powr Labs), reads RR intervals from the standard Heart Rate Service, and shows artifact-filtered RMSSD live and per recorded session. Native Swift (SwiftUI, CoreBluetooth, Swift Charts) with no dependencies. All data stays on the device.

## Build and install

```sh
open HRV.xcodeproj    # pick your iPhone, press Run
```

Or from the command line:

```sh
xcodebuild build -scheme HRV -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates
xcrun devicectl device install app --device <device-id> build/Build/Products/Debug-iphoneos/HRV.app
```

Signing uses a paid Apple Developer Program team, so development installs stay valid for a year (until the provisioning profile expires).

Tests: `xcodebuild test -scheme HRV -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`

## How HRV is computed

- **Parsing** (`HRV/Core/HeartRateParser.swift`): 0x2A37 packets carry RR in units of 1/1024 s. These are converted to ms.
- **Artifact filter** (`ArtifactFilter.swift`): a beat is valid if it falls within 300–2000 ms and within 20% of the median of the last 5 accepted beats. Strap-reported loss of skin contact also invalidates beats. After start-up or a disconnect, beats are rejected until 3 consecutive beats agree. A sustained genuine rhythm change is adopted the same way.
- **RMSSD** (`HRVCalculator.swift`): uses only successive pairs where both beats are valid and no gap lies between them. Windows are 30 s, 60 s or 5 min. No value is shown ("—" plus a reason) when:
  - the window isn't 90% filled yet,
  - more than 20% of its beats are artifacts,
  - clean pairs cover less than 70% of the window, or
  - there are fewer than 20 clean pairs (30 s window) or 40 (60 s / 5 min).
- The live chart samples every 5 s and keeps the last 30 min. Lines break across gaps.

## Recording, tags and change prompts

- **Always on:** every beat is saved while the strap is connected. Each local day is stored as `Documents/days/YYYY-MM-DD.csv` with columns `epoch_ms,rr_ms,valid,bpm,event`, and disconnects are marked as `gap` rows. History recomputes HRV from the raw RR intervals, so any window works on past days.
- **Tags:**
  - Quick buttons on the Live tab, or "Other…" to type your own label.
  - In History, drag across a day's chart to pick a moment and tag it.
  - Tags are stored in `days/tags.json`.
- **Change prompts** (`Core/ChangeDetector.swift`, `Notifications/ChangePrompter.swift`):
  - The 60s RMSSD is compared with the median of the past hour, leaving out the last 5 minutes.
  - A prompt fires when ≥85% of the last 2 minutes sit ≥35% below that baseline, or ≥50% above it.
  - It requires at least 20 minutes of baseline, and the iPhone motion sensor must not show walking, running or cycling.
  - At most one prompt every 45 minutes, and none within 15 minutes of a manual tag.
  - Each detected change becomes a tag. Between 22:00 and 07:00 the tag is recorded without a notification.
  - You can answer from the Lock Screen with a typed reply or a quick option.
- The Strap tab shows strap battery when the strap reports it.
- **Live Activity** (`HRVWidget/`, `HRV/LiveActivity/`):
  - Shows current HRV and HR on the Lock Screen, and in the Mac menu bar on macOS 26+ when iPhone Mirroring is set up.
  - It starts when the app is in the foreground with the strap connected, and updates at most every 10 s from the background.
  - It ends as soon as the strap disconnects. iOS doesn't let it restart from the background, so it reappears the next time you open the app with the strap connected.
  - Swiping the app away ends it too (best effort: iOS only tells the app while it's running, which it is while the strap streams). If it's missed, it shows "No recent data" after 90 s and is removed the next time you open the app.
- **Swiping the app away stops recording:** iOS doesn't relaunch an app you swiped away, so it won't reconnect to the strap until you open it again.
  - It shows "—" after 90 s without data.
  - iOS ends it after about 8 hours, and it restarts the next time you open the app.

## Background behaviour (iOS limits)

- With the `bluetooth-central` background mode, recording and change detection continue when the screen is locked or you switch apps.
- If the strap drops out, a pending reconnect stays active and it resumes automatically when back in range, including in the background. The gap is marked and HRV never spans it.
- If iOS terminates the app for memory, Bluetooth state restoration relaunches it and recording continues.
- **If you swipe the app away in the app switcher, iOS stops all Bluetooth delivery.** Recording pauses until you open the app again.

## Troubleshooting: strap doesn't send RR intervals

Most chest straps send RR intervals, which HRV needs. If one doesn't, the Live tab says "Strap doesn't send RR intervals" after about 15 s. To check a strap from the Mac, put it on (it wakes on skin contact), make sure it isn't connected to your phone or another app, then run:

```sh
swift tools/hrscan.swift            # or: swift tools/hrscan.swift powr
```

Each notification prints with its flags, BPM and RR values. After Ctrl-C you get a PASS/FAIL summary. Terminal needs Bluetooth permission (System Settings → Privacy & Security → Bluetooth).
