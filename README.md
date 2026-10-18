# Dosely

A calm, minimal medication administration record (MAR) and reminder app for iPhone. SwiftUI + SwiftData + AlarmKit, iOS 26.

## First install (once, with Xcode)

1. Open `Dosely.xcodeproj` in **Xcode 26** or later and sign in under *Xcode ▸ Settings ▸ Accounts*.
2. Select the **Dosely** target ▸ *Signing & Capabilities* ▸ choose your Team.
   (Or skip this: `scripts/install.sh` auto-detects your team and writes it to `Config/Local.xcconfig`.)
3. Plug in the iPhone, tap **Trust**, turn on *Settings ▸ Privacy & Security ▸ Developer Mode*, and press Run.

That pairs the phone with your Mac. From then on you don't need to open Xcode.

## Every install after that — over Wi‑Fi, from Terminal

```bash
cd Dosely
./scripts/install.sh
```

The script builds a Release copy, finds your paired iPhone (Wi‑Fi or USB), installs it over the existing app (your data is kept) and opens it. A typical rebuild takes under a minute.

| Command | What it does |
|---|---|
| `./scripts/install.sh` | Build → install → launch (remembers the last device) |
| `./scripts/install.sh --list` | Show paired devices and whether they're on Wi‑Fi or USB |
| `./scripts/install.sh --device "Eric's iPhone"` | Pick a device by name, UDID or identifier |
| `./scripts/install.sh --debug` | Debug build instead of Release |
| `./scripts/install.sh --no-launch` | Install without opening the app |
| `./scripts/install.sh --clean` | Wipe the build folder first |
| `./scripts/install.sh --team ABCDE12345` | Set or change the signing team |

For Wi‑Fi installs, the phone must be **unlocked, awake and on the same network** as the Mac. If it was just restarted, unlock it once. If it still can't be found, plug it in by USB one time and try again.

Tips:
- A free (personal) Apple ID signs apps for 7 days. Just rerun the script to refresh.
- If Xcode says the bundle ID is taken, add `PRODUCT_BUNDLE_IDENTIFIER = com.yourname.dosely` to `Config/Local.xcconfig`. Changing the bundle ID installs a separate app with a fresh database.
- Logs are in `build/build.log` and `build/install.log`. Install `xcbeautify` (`brew install xcbeautify`) for tidier build output.
- Each install stamps a new build number, which makes the app rebuild every alarm the next time it launches.

## How scheduling works

- **Convergence time** (default 09:00) anchors everything. QD falls at 09:00, BID at 09:00/21:00, Q6H at 03:00/09:00/15:00/21:00, and so on.
- **Bedtime** (default 21:00) anchors QHS. TID and QID are spread across the waking day (09:00·15:00·21:00 and 09:00·13:00·17:00·21:00); turn that off for strict around-the-clock spacing.
- **Long schedules:**
  - *Every other day* and *Every N days* (2–90) count from the first dose.
  - *Weekly* runs on any set of weekdays, every 1–12 weeks (e.g. Mon & Thu every 2 weeks).
  - *Monthly* runs every 1–24 months on the first dose's day of the month. The 29th–31st fall back to the last day of shorter months.
  - All of them default to the convergence time; any medication can set its own times.
- Each frequency's default times can be overridden in Settings, and each medication can override its own.
- **Last dose** marks the final administration (inclusive). Course chips compute it: 3–28 days for daily schedules, or 4 weeks to 1 year for long ones.

## Using the board

- **Charting:** tap a box to chart it; tap again to clear it (with Undo). Long-press for *Taken now*, *Taken at scheduled time*, *Skipped*, *Missed* or *Details…*. The Details sheet also offers Taken / Skipped / Missed / Clear, with a note for the reason.
- **Colours:** sage ✓ = given, grey – = skipped, solid clay ✕ = charted as missed, clay outline = overdue and not yet checked off, honey = due now, plain outline = upcoming, lavender = PRN, dashed = optional PRN reminder.
- The export distinguishes *✗ missed* (charted) from *? not charted*.
- **Long schedules on the board:** weekly and monthly medications only show boxes on their dosing days, and their details card shows the next due date.
- **PRN rows** have a **+** for one-tap logging.
- **Now button:** recentres the timeline.

## Alarms (AlarmKit)

- **One alarm per moment.** Every medication due at the same time rings as one alarm, titled with every name (e.g. "Metformin, Atorvastatin & Vitamin D3"). Its **All taken** button charts each of them against its own slot. In *Settings ▸ Combine alarms* you can also merge doses within 15, 30 or 60 minutes of each other.
- **Full rebuild on every schedule change.** The app stores a fingerprint of everything that decides alarm times: medications, times, recurrence, course dates, settings, time zone and app build.
  - Whenever the fingerprint changes, every Dosely alarm is cancelled and the whole window is rebuilt from scratch. That covers each alarm AlarmKit reports and each one in the app's own cache.
  - Saving, archiving, deleting or reordering a medication, changing any setting, or changing time zone or clock all trigger this.
  - Charting a dose only removes or reshapes the affected alarm.
- **Window:** 62 days ahead, up to 60 alarms. Each medication's next two alarms are always included, so weekly and monthly doses aren't crowded out by frequent ones.
- **Rings again until checked off.** If you tap **Dismiss** without charting the dose, it rings again after the interval in *Settings ▸ Ring again after* (default 20 minutes), over and over, until the dose is charted as taken, skipped or missed.
  - Repeats show as "Still due · …". Overdue doses for different medications are merged into one repeating alarm.
  - Each Dismiss restarts the countdown from that moment.
  - If an alarm times out without a tap, the pre-scheduled repeats carry on (every repeat in the next 6 hours, plus three after every future dose). Each app launch, background refresh or Dismiss extends the chain.
  - A dose stops repeating when the same medication's next dose comes due, and that dose takes over. It then shows as overdue on the board until you chart it.
  - PRN reminders don't repeat. Doses from before a medication was added (back-filled history) never ring.
  - Turn it off with *Settings ▸ Repeat until checked off*.
- *Settings ▸ Upcoming alarms* lists exactly what is scheduled, and pull-to-refresh forces a rebuild.
- **Alert style:** vibrate only uses a bundled silent clip, so the alarm vibrates without sound. PRN medications never ring unless you opt in for that medication.

## Project layout

| Area | Files |
|---|---|
| Data model | `Dosely/Models/Medication.swift` |
| Schedule maths & recurrence | `Dosely/Core/ScheduleSettings.swift`, `Dosely/Core/ScheduleEngine.swift` |
| Timeline grid | `Dosely/Core/TimelineModel.swift`, `Dosely/Views/MARGrid.swift`, `Dosely/Views/RootView.swift` |
| Editor, details, dose sheet | `Dosely/Views/MedicationEditor.swift`, `MedicationDetailCard.swift`, `DoseSheet.swift` |
| Alarms | `Dosely/Alarms/AlarmScheduler.swift` |
| Export | `Dosely/Core/ExportBuilder.swift`, `Dosely/Views/ExportView.swift` |
| Signing & install | `Config/Signing.xcconfig`, `scripts/install.sh` |

Dosely is a personal record and reminder tool, not medical advice.
