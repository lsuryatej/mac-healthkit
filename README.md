# mac-healthkit

A suite of bash scripts for macOS Apple Silicon that does what paid tools like **iStatMenus**, **CleanMyMac**, and **Sensei** lock behind paywalls — using only native macOS tools.

**Zero dependencies. Zero cloud. Zero install beyond cloning the repo.**

---

## Why this exists

Every paid Mac monitoring app charges $10–$40/year to show you information your Mac already exposes for free via `ps`, `vm_stat`, `memory_pressure`, `powermetrics`, and `launchd`. This project wires those tools together into a cohesive, automatable toolkit aimed at Apple Silicon Macs (M1 through M5).

---

## What's included

| Script | What it does | Runs |
|---|---|---|
| `mac_check.sh` | Full on-demand health diagnostic | On demand |
| `mac_logger.sh` | Appends one CSV row of health metrics | Every 5 min (launchd) |
| `mac_weekly_report.sh` | Reads the CSV log, outputs trend summary | On demand |
| `mac_disk_diff.sh` | Snapshots `~/Library` dirs, diffs vs last week | On demand |
| `mac_watch.sh` | Passive alerter — sends native notifications on threshold breach | Every 10 min (launchd) |
| `personas/engineer.sh` | `mac_check.sh` in terse, PID-level dev mode | On demand |
| `personas/designer.sh` | `mac_check.sh` in plain-English, emoji mode | On demand |

---

## Requirements

- macOS 14 Sonoma or 15 Sequoia
- Apple Silicon (M1/M2/M3/M4/M5) — Intel Macs will mostly work but are untested
- No Homebrew, no Python, no npm, no nothing

---

## Install

```bash
git clone https://github.com/yourusername/mac-healthkit.git
cd mac-healthkit
bash install/install.sh
```

This will:
- Make all scripts executable
- Copy the two launchd plists to `~/Library/LaunchAgents/`
- Load both agents (logger + watcher)
- Create `~/.mac-healthkit/logs/` and `~/.mac-healthkit/snapshots/`

---

## How to run each script

### On-demand health check

```bash
bash scripts/mac_check.sh
```

For power draw (requires sudo):

```bash
sudo bash scripts/mac_check.sh
```

### Persona views

```bash
bash personas/engineer.sh   # terse, numbered, PID-level
bash personas/designer.sh   # plain English, traffic-light emojis
```

### Weekly trend report

```bash
bash scripts/mac_weekly_report.sh
```

Reads `~/.mac-healthkit/logs/health.csv`. Shows:
- Load average trends (avg, peak, distribution)
- Memory pressure distribution (% of time healthy/moderate/critical)
- Top 5 most frequent CPU offenders
- Top 5 worst memory events with timestamps
- Swap event count

### Disk diff

```bash
bash scripts/mac_disk_diff.sh
```

First run takes a snapshot. Subsequent runs compare against the most recent snapshot and flag any `~/Library` subdirectory that grew by more than 500 MB, with specific fix commands for known bloat sources (Claude vm_bundles, Chrome OptimizationGuide, Docker images, Xcode DerivedData).

---

## The persona system

`mac_check.sh` accepts a `--persona` flag:

```bash
bash scripts/mac_check.sh --persona engineer   # default
bash scripts/mac_check.sh --persona designer
```

**Engineer persona:**
- Numbered sections `[01]` through `[06]`
- Status labels: `▶ nominal`, `▶ elevated`, `▶ CRITICAL`
- Shows PIDs, exact MB, raw process paths alongside normalised names
- No hand-holding, just data and kill commands

**Designer persona:**
- Traffic-light emojis: 🟢 🟡 🔴
- Plain English — "Your Mac is working very hard right now"
- Hides PIDs, rounds MB to nearest 100
- One-sentence explanation per finding
- Fix commands labelled "run this in Terminal"

The `personas/` wrappers are thin one-liners — the logic lives entirely in `mac_check.sh`.

---

## How the logger + weekly report work together

```
launchd (every 5 min)
  └─▶ mac_logger.sh
        └─▶ appends one row to ~/.mac-healthkit/logs/health.csv

You (any time)
  └─▶ mac_weekly_report.sh
        └─▶ reads health.csv → trend analysis
```

CSV format:
```
timestamp, load_1m, load_5m, load_15m, mem_free_pct, swap_out_total,
compressed_pages, top_cpu_proc, top_cpu_pct, top_mem_proc, top_mem_mb, cpu_power_mw
```

Log rotation: when `health.csv` exceeds 50 MB it is moved to `health.csv.1` and a fresh file starts.

---

## Background watcher

`mac_watch.sh` runs every 10 minutes via launchd. It sends native macOS notifications (no third-party notification library) when:

| Threshold | Alert |
|---|---|
| Load avg (1m) > 6 | Notification with top process name |
| Free memory < 15% | Notification with top memory process |
| Any process > 3 GB RAM | Notification with process name + kill command |
| Any WebKit tab > 800 MB | Notification with PID |

**Debounce:** the same alert won't fire again for 30 minutes. State is stored in `~/.mac-healthkit/watch_state.txt`.

---

## Known culprit detection

`mac_check.sh` checks for these specific known issues on every run:

| Culprit | Detection | Fix |
|---|---|---|
| iWork RAM leak (Pages/Numbers/Keynote) | RSS > 1.5 GB | Quit and reopen the app |
| Notion GPU Helper polling bug | GPU helper > 10% CPU | `killall 'Notion Helper (GPU)'` |
| iCloud bird heavy sync | bird > 20% CPU | `killall bird` |
| Spotlight overload | >8 mdworker/mds_stores procs | `sudo mdutil -a -i off && on` |
| Heavy WebKit tabs | Any WebContent > 500 MB | Close tabs |
| Brave renderer flood | >8 Brave renderer procs | Close tabs |
| Docker CPU hog | Docker > 10% CPU combined | `docker stats --no-stream` |
| Python/Jupyter runaway | Python > 20% CPU combined | Check running scripts |
| Node.js / Next.js | Node > 15% CPU combined | Check dev servers |
| VPN memory leak | VPN processes > 300 MB | Restart VPN client |

---

## Process name normalisation

Raw macOS process names are normalised for readability:

| Raw name | Normalised |
|---|---|
| `WebKit.WebContent` / `WebContent` | `Safari Tab` |
| `Brave.*Renderer` | `Brave Tab` |
| `mds_stores` / `mdworker` | `Spotlight` |
| `bird` | `iCloud Sync` |
| `kernel_task` | `kernel [skip]` |
| `sysmond` | `sysmond [skip]` |

---

## Uninstall

```bash
bash install/install.sh --uninstall
```

This unloads the launchd agents, removes the plists from `~/Library/LaunchAgents/`, and leaves your log data intact. To also remove logs:

```bash
rm -rf ~/.mac-healthkit
```

---

## Comparison vs paid tools

| Feature | mac-healthkit | iStatMenus ($10/yr) | CleanMyMac ($40/yr) | Sensei ($29/yr) |
|---|---|---|---|---|
| Live CPU / memory stats | ✅ | ✅ | ✅ | ✅ |
| Named process breakdown | ✅ | ✅ | ⚠️ basic | ✅ |
| Known app culprit detection | ✅ | ❌ | ❌ | ❌ |
| Background CSV logging | ✅ | ❌ | ❌ | ❌ |
| Weekly trend report | ✅ | ❌ | ❌ | ❌ |
| Disk growth diff | ✅ | ❌ | ✅ paid | ⚠️ basic |
| Native notifications (no app) | ✅ | ✅ | ❌ | ❌ |
| Persona output modes | ✅ | ❌ | ❌ | ❌ |
| `powermetrics` power draw | ✅ (sudo) | ✅ | ❌ | ✅ |
| Zero install / dependencies | ✅ | ❌ | ❌ | ❌ |
| Open source | ✅ GPL-3.0 | ❌ | ❌ | ❌ |
| Price | **Free** | $10/yr | $40/yr | $29/yr |

---

## `NO_COLOR` support

All colored output is suppressed when the `NO_COLOR` environment variable is set (per [no-color.org](https://no-color.org)):

```bash
NO_COLOR=1 bash scripts/mac_check.sh
```

---

## License

GPL-3.0. You can use, modify, and redistribute this freely. You may **not** incorporate it into a proprietary or paid product without releasing your modifications under the same license. See [LICENSE](LICENSE) for the full text.
