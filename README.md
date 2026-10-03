<div align="center">

# Auto Pause Mac Apps

**A 100% free, open-source macOS menu bar app that pauses apps you're not using and gives their RAM back — then resumes them exactly where you left off.**

[![Download](https://img.shields.io/badge/Download-Free%20DMG-blue?style=for-the-badge)](https://github.com/fazalrshah/auto-pause-mac-apps/releases/latest)
![Price](https://img.shields.io/badge/Price-100%25%20Free%20Forever-brightgreen?style=for-the-badge)
![Platform](https://img.shields.io/badge/macOS-14%2B-lightgrey?style=for-the-badge)
![Arch](https://img.shields.io/badge/Universal-Apple%20Silicon%20%2B%20Intel-black?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-green?style=for-the-badge)

</div>

---

## What is Auto Pause Mac Apps?

**Auto Pause Mac Apps** is a free Mac menu bar utility that suspends (freezes) running
applications so macOS can reclaim their memory, and resumes them instantly when you need them
again. It is the Mac equivalent of putting an app in suspended animation: the app stops using
CPU, its RAM becomes reclaimable, and nothing about your session is lost.

It has two levels:

1. **Pause** — freezes the app in place. Resume is instant and byte-perfect.
2. **Deep Sleep** — quits the app while preserving its state, releasing **all** of its memory
   *including swap*. Waking relaunches it and restores your windows and tabs.

It is **100% free**, open source under the MIT license, has no ads, no subscription, no account,
no telemetry, and no paid tier. There is nothing to buy.

---

## Real problems this solves

| Situation | What you do | What you get back |
|---|---|---|
| **Running a local LLM** (Ollama, LM Studio, llama.cpp) and there isn't enough free RAM | Open **Free Up Memory**, set a target of 8 GB, click once | Enough headroom to load the model, then one click to restore everything |
| **Chrome or Edge is eating 6 GB** while you work in another app | Pause the browser | Gigabytes back, every tab exactly where it was when you resume |
| **Claude, Codex, Cursor and Docker all open at once** and your Mac starts swapping | Pause the two you aren't touching | Memory pressure drops out of the red without closing anything |
| **You're on battery and want it to last** | Pause background apps | They stop consuming CPU entirely, not just "less" |

---

## Screenshots

### The main panel — every app, ranked by real memory use

![Auto Pause Mac Apps menu bar panel on macOS showing four frozen apps pinned at the top and running apps including Microsoft Edge at 3.22 GB and Claude at 2.03 GB with live memory sparklines](docs/screenshots/main-panel.png)

Two sections:

- **Suspended (top)** — Messages, Mail, Calendar and TextEdit are `FROZEN`, each with a green
  button to bring them straight back. They pin to the top so a frozen app is never lost.
- **Apps** — running apps sorted by the RAM they actually hold, each with a live sparkline and
  buttons to Pause (⏸), Deep Sleep (🌙) or open details.

The footer holds **Free Up Memory**, **Resume All**, settings and quit.

Look at the frozen **Mail** row: `9.5 MB` resident against `399.9 MB` footprint. Mail is holding
9.5 MB of real RAM — the other ~390 MB has already been compressed or swapped out. That gap is
exactly what tools showing only Activity Monitor's footprint number hide from you.

### Free Up Memory — review, then confirm

![Free Up Memory dialog with a target slider set to 8 GB, warning that only about 7.42 GB is available to free, and a Free 8 GB button](docs/screenshots/free-up-memory.png)

*(Screenshot from 1.2. In 1.3 this became a reviewable checklist — see below.)*

Clicking **Free Up Memory** now shows you every app it proposes to pause, with its memory cost
and a tickbox. Untick anything you're still using. **Nothing is paused until you press the
confirm button.**

- Your **frontmost app** is never listed.
- **Auto Pause itself is never listed**, and refuses to freeze any process tree containing
  itself — at the signal layer, not just in the selection logic.
- **Recording and call apps** (QuickTime, OBS, ScreenFlow, Loom, Zoom, Teams, Meet, Discord,
  Slack…) start **unticked** and are flagged *"may be recording or in a call"*.
- **Background services and daemons are never touched** — see below.
- Optionally remember your opt-outs so those apps are never offered again.

Afterwards, **Restore** puts back exactly the set it paused, leaving anything you froze by hand
still frozen.

### System dashboard — where your memory actually went

![Memory pressure dashboard showing a 77 percent ring gauge marked Warning, a usage history graph, and a breakdown of App 5.06 GB, Wired 2.43 GB, Compressed 4.97 GB, Free 436.5 MB and Swap Used 4.4 GB](docs/screenshots/system-dashboard.png)

A real pressure gauge with Normal / Warning / Critical thresholds, usage history, and the full
breakdown from `host_statistics64`: **App 5.06 GB · Wired 2.43 GB · Compressed 4.97 GB · Free
436.5 MB · Swap 4.4 GB**.

This view explains why "Memory Used" can look stuck. Nearly 5 GB here is *compressed* — data
macOS has already squeezed to make room. Compressed pages still count as used, so the headline
number stays high even while apps are being frozen and memory is genuinely being reclaimed.

### Per-app detail — memory history and automatic pausing

![Microsoft Edge detail popover showing 3.83 GB in RAM of 6.57 GB total, a memory graph over the last 120 seconds, an auto-pause when idle toggle, and a Pause Now button](docs/screenshots/app-detail.png)

Every app has a detail view with its resident-vs-total split (**Edge: 3.83 GB in RAM · 6.57 GB
total**), a rolling two-minute memory graph, and **Auto-pause when idle** — freeze this app
automatically after N minutes in the background, thaw it when you come back. Off by default,
set per app.

### Frozen apps stay visible and instantly resumable

![TextEdit detail popover showing the app frozen at 22.9 MB in RAM of 58.8 MB total with a Resume button](docs/screenshots/frozen-app.png)

A frozen app keeps its row and its numbers — TextEdit sits at **22.9 MB in RAM · 58.8 MB
total** — and one click resumes it exactly where it was. Nothing is closed, nothing is lost.

---

## Install

### Recommended: one-line installer (no warnings)

```bash
curl -fsSL https://raw.githubusercontent.com/fazalrshah/auto-pause-mac-apps/main/install.sh | bash
```

Downloads the latest release, installs it to `/Applications`, clears the download quarantine
flag and launches it. That last step is what prevents the *"Apple could not verify…"* dialog.
[Read the script first](install.sh) — it's short and does exactly that, nothing else.

### Or: Homebrew

```bash
brew tap fazalrshah/tap
brew trust --cask fazalrshah/tap/auto-pause-mac-apps
brew install --cask auto-pause-mac-apps
```

Recent Homebrew versions refuse to load casks from third-party taps until you trust them
explicitly, hence the middle step. Homebrew clears the quarantine flag too, so the app opens
normally. Update later with `brew upgrade --cask auto-pause-mac-apps`.

### Or: download the DMG manually

**[⬇ Download AutoPauseMacApps-1.2.0.dmg →](https://github.com/fazalrshah/auto-pause-mac-apps/releases/latest)**

1. Open the DMG and drag **Auto Pause Mac Apps** into Applications.
2. Double-click it. macOS will say *"Apple could not verify… is free of malware"* — this is
   expected (see below). Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll to Security, and click
   **Open Anyway** next to Auto Pause Mac Apps. Confirm with Touch ID or your password.

> **On macOS 15 and later, right-clicking → Open no longer bypasses this.** The
> **Privacy & Security → Open Anyway** route above is the only way. You only do it once.

To skip step 3 entirely, use Homebrew or the installer above — or clear the flag yourself:

```bash
xattr -dr com.apple.quarantine "/Applications/Auto Pause Mac Apps.app"
```

### Why does macOS show that warning?

Because the app isn't **notarized**. Notarization requires a "Developer ID Application"
certificate, which Apple issues only to **paid** Apple Developer Program members at
**$99/year**. This app is free, has no ads, no subscription and no revenue, so that certificate
isn't in place yet.

The warning does **not** mean anything was detected in the app. It means Apple hasn't been paid
to check it. What you can do instead of taking my word for it:

- **Read the source.** It's all here, dependency-free, and [documented module by module](docs/ARCHITECTURE.md).
- **Build it yourself** in one command (below) — then it's your own binary, no warning.
- **Verify the download** against the checksum published in each [release](https://github.com/fazalrshah/auto-pause-mac-apps/releases).

If the project ever gets funded, [`notarize.sh`](notarize.sh) is already written and will make
the warning disappear for everyone.

**Maintainer:** Fazal Shah — [github.com/fazalrshah](https://github.com/fazalrshah). MIT licensed.

### Build from source

Requires only Xcode Command Line Tools — no Xcode install needed.

```bash
git clone https://github.com/fazalrshah/auto-pause-mac-apps.git
cd auto-pause-mac-apps
./build.sh                 # native build
./build.sh --universal     # Apple Silicon + Intel
./package-dmg.sh 1.2.0     # build the DMG
```

`build.sh` signs with a Developer ID automatically if you have one installed, and falls back to
ad-hoc signing if you don't.

---

## Features in detail

### ⏸ Pause — freeze any app instantly

Sends `SIGSTOP` to the app **and every helper process it owns**. CPU use drops to zero and
macOS reclaims the app's resident memory. `SIGCONT` resumes it byte-perfectly — same scroll
position, same undo history, same unsaved text.

*Why the process tree matters:* Chrome's memory isn't in Chrome. It's spread across ~25
`Google Chrome Helper` processes. Freezing only the parent frees almost nothing, which is why
naive "app pauser" scripts don't work on browsers.

### 🌙 Deep Sleep — free everything, including swap

Quits the app the normal way — the same as pressing ⌘Q — so macOS and the app save state
first. This is the only mechanism on macOS that returns **100% of an app's memory, swap
included**. Waking relaunches it and restores your windows and tabs in seconds.

Before the first use it shows a warning explaining exactly what will happen, tells you whether
*that specific app* will restore its windows, and offers to enable window restore for it.

### 🧠 Free Up Memory — the local model button, with a safety net

Need several GB free to load a model? Click **Free Up Memory**, review the proposed list,
untick anything you're using, and confirm. It pauses exactly what you approved — never your
frontmost app, never itself, and never a background service.

**Restore** undoes precisely that set, leaving anything you froze by hand alone.

### 🛡️ What it will never touch

Auto Pause only ever pauses **apps you explicitly approve**, plus the helper processes those
apps own. It does not enumerate, display or freeze background services and daemons.

Version 1.2 did list and freeze them, and it was a mistake: freezing system daemons could leave
a Mac hard to operate, and a single click could pause something critical with no warning. That
capability was removed rather than patched.

### 📊 Honest memory numbers

Each row shows two figures, and the gap between them is the entire point:

- **Resident** (large) — RAM held *right now*. This is what drops when you pause.
- **Footprint** (dim) — Activity Monitor's "Memory" column, which also counts pages already
  compressed or swapped to disk, so it barely moves even after the RAM is reclaimed.

Measured on a 16 GB M1 with Chrome frozen:

```
Google Chrome — footprint 4.31 GB · resident 275 MB
```

Freezing returned roughly **4 GB of actual RAM** while the footprint number hardly moved. Tools
that display only footprint make pausing look like it did nothing at all.

### 🎬 Guided first run

Because the app has no Dock icon and no window, a menu-bar-only utility can vanish the moment
you install it. A short animated walkthrough runs on first launch: what the two tiers do, how
Free Up Memory works, and an arrow pointing at where in the menu bar to find it — plus the
option to start at login. You can reopen it any time from **Settings ▸ Show the walkthrough again**.

### 🚀 Start at login

Toggle it on in **Settings** (the gear in the footer) and the app registers itself with macOS's
modern login-items system via `SMAppService` — the same list in System Settings ▸ General ▸ Login
Items. No helper bundle, no deprecated APIs. The toggle reads the status back after registering
rather than assuming it worked, so if macOS wants approval or the app isn't in `/Applications`
it tells you instead of silently failing.

### ⏱ Auto-pause when idle

Per app, off by default: freeze automatically after N minutes in the background, thaw on return.
The idle check runs every 30 seconds whether or not the panel is open. Bringing any frozen app
to the front (Dock click, Cmd-Tab, `open -a`) thaws it, however it was frozen.

---

## FAQ

### Is it really free?

Yes — 100% free, forever. MIT licensed, no ads, no subscription, no account, no telemetry, no
paid upgrade. The complete source is in this repository.

### Will I lose my work?

No. Pause never touches your data — the app is frozen in memory, exactly as it was. Deep Sleep
quits the app the normal way: apps that autosave save first, and apps that don't show their usual
"Do you want to save?" dialog and stay open, in which case the app is left frozen instead.
**Nothing is ever force-quit.** No `SIGKILL`, ever.

### Why does macOS say "Apple could not verify this app"?

Because it isn't notarized — Apple only issues the required certificate to paid Developer
Program members ($99/year), and this app is free. Nothing was detected in it. Install via
Homebrew or the one-line installer and you won't see the dialog at all; or clear the flag with
`xattr -dr com.apple.quarantine "/Applications/Auto Pause Mac Apps.app"`. On macOS 15+,
right-click → Open no longer works — use System Settings → Privacy & Security → Open Anyway.

### Does it need root, a password, or special permissions?

No. It uses Unix signals and Apple's public `libproc` APIs, which work on processes owned by your
own user account by design. No root, no kernel extension, no entitlements, no accessibility or
automation prompts.

### Does pausing an app actually free RAM?

Yes, but read the *resident* number, not the footprint. On a test machine, freezing Chrome took it
from 4.31 GB footprint to 275 MB resident. If your Mac is heavily oversubscribed, the system-wide
"Memory Used" gauge may not drop, because macOS immediately reuses freed pages for active apps —
that's macOS working correctly. Use Deep Sleep when you need the total to actually fall.

### How is this different from force-quitting an app?

Force-quitting destroys your session — tabs, windows, unsaved work. Pause freezes the app with
everything intact, and Deep Sleep quits it only after state is saved so it comes back as it was.

### Does it work on Apple Silicon (M1/M2/M3/M4) and Intel?

Yes. The release DMG is a universal binary for both. macOS 14 (Sonoma) or later.

### Can I pause Chrome, Edge, Safari, Slack, Docker, or Electron apps?

Yes. Because it freezes the whole process tree, multi-process apps like Chromium browsers and
Electron apps (Slack, VS Code, Discord) are handled correctly — that's where most of the memory
actually lives.

### Which processes will it refuse to touch?

Auto Pause only pauses regular apps you explicitly approve, plus the helper processes those apps
own. Background services and system daemons are never listed or touched at all. It also refuses
to freeze itself or any process tree containing itself — enforced when the signal is sent, so it
holds regardless of what the UI asks for — and it can only ever signal processes owned by you.

### What happens if the app crashes while things are frozen?

Frozen and sleeping apps are recorded on disk, so they stay listed and resumable next launch.
Quitting the app normally resumes everything automatically.

### Can it snapshot an app to disk and restore it later?

No — and nothing on macOS can. [CRIU](https://github.com/checkpoint-restore/criu) does this on
Linux using `ptrace`, `/proc` and parasite code injection, none of which exist on macOS, and
`task_for_pid` is restricted by SIP. A state-preserving quit (Deep Sleep) is the closest
achievable equivalent.

---

## How it works

| Capability | Mechanism |
|---|---|
| Freeze / resume | `SIGSTOP` / `SIGCONT` across the full process tree |
| Process discovery | `proc_listchildpids`, `proc_listpids` |
| Memory measurement | `proc_pid_rusage` → `ri_resident_size` and `ri_phys_footprint` |
| Frozen-state detection | `proc_pidinfo` → `pbi_status == SSTOP` |
| System memory | `host_statistics64` + `sysctl vm.swapusage` |
| Deep Sleep | `NSRunningApplication.terminate()` + macOS state restoration |
| Wake | `NSWorkspace.openApplication` |

Apple's own guidance is to prefer `libproc` over `task_for_pid()`, which SIP restricts to
development tools. That's why this needs no entitlements and prompts you for nothing.

📖 **[Full architecture — module by module →](docs/ARCHITECTURE.md)**

---

## Known limitations

- A frozen app beachballs if you click it and shows "Not Responding" in Activity Monitor. Expected.
- Don't freeze an app mid-call or mid-upload — network connections will drop.
- Window-restore quality after Deep Sleep varies by app. Browsers use their own "Continue where
  you left off" setting instead of macOS's, and the app checks it for you.

## Contributing

Issues and pull requests welcome. The codebase is small, dependency-free, and
[documented module by module](docs/ARCHITECTURE.md).

## License

MIT — free to use, modify and redistribute. See [LICENSE](LICENSE).
