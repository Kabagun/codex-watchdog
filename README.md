# Codex Remote Watchdog

This Windows watchdog protects Codex Desktop and Mobile Remote from locally
observable crashes and task-lifecycle freezes. It checks once per minute while
the installing user's desktop session is logged in. It does not restart Codex merely
because Codex is idle.

## Requirements

- Windows with Codex Desktop installed from the `OpenAI.Codex` AppX package.
- PowerShell 7 (`pwsh.exe`) and `sqlite3.exe` available on the current user's
  `PATH`.
- An interactive Windows session that remains logged in, powered on, awake,
  and online.
- An enabled Codex Desktop Remote enrollment.

Check the installed program paths with `Get-Command pwsh.exe, sqlite3.exe`.
Keep `CodexWatchdog.ps1` and `CodexWatchdogLauncher.vbs` together in a stable
directory. The scheduled task records their absolute paths; run `Install`
again if you move the directory.

## Commands

Run these from PowerShell 7 in this repository's directory:

```powershell
$watchdog = (Resolve-Path .\CodexWatchdog.ps1).Path

# Read current status without changing watchdog state.
pwsh -NoProfile -File $watchdog -Action Status

# Show what an automatic check would do, without changing anything.
pwsh -NoProfile -File $watchdog -Action Check -WhatIf -Json

# Inspect the ordinary logon launch route without launching Codex or querying Remote/SQLite.
pwsh -NoProfile -File $watchdog -Action LaunchOnly -WhatIf -Json

# Install or update the scheduled task.
pwsh -NoProfile -File $watchdog -Action Install -Json

# Explicitly restart Codex. This can interrupt active local work.
pwsh -NoProfile -File $watchdog -Action Restart -WhatIf -Json
pwsh -NoProfile -File $watchdog -Action Restart -Json

# Remove the scheduled task. Diagnostics are intentionally retained.
pwsh -NoProfile -File $watchdog -Action Uninstall -Json
```

The installed task is `\Codex\Codex Remote Watchdog`. It starts at logon and
repeats every minute with `InteractiveToken`, `LeastPrivilege`, and
`IgnoreNew` instance policy. Its execution limit is three minutes. The task
runs through `wscript.exe` and `CodexWatchdogLauncher.vbs`, which launches
PowerShell with window style `0`; routine checks therefore create no console
window or taskbar flash.

## Enhanced launch and existing autostart

Every recovery resolves the current user's canonical
`$HOME\.agents\skills\better-codex\scripts\codex-custom.ps1`. When the skill is
installed, the watchdog calls its current wrapper through PATH PowerShell 7.
It supplies no width, runtime or administrator option: normal Enhanced launch,
saved preferences and future skill updates remain owned by better-codex.
An incomplete skill or failed Enhanced launch is reported rather than silently
bypassed. If the skill is absent, the existing Windows package activation path
remains the fallback.

`-Action LaunchOnly` shares that selector but does not use Remote enrollment,
SQLite health or recovery state as a prerequisite for ordinary app startup.
It can apply normal Enhanced settings to an existing app; when the skill is
absent and native Codex is already running, it does nothing. This action never
closes or force-stops an application. A launch request does not prove rendered
width, icon appearance or any actual process privilege.

`Set-CodexStartupLauncher` can explicitly create/read back one owned
`Codex Enhanced.lnk` in the current user's Startup folder. Its hidden VBS action
calls this same watchdog source with `LaunchOnly`, so removing the skill later
still leaves a functional native fallback. The ordinary watchdog `Install`
action does not create this app-start entry or enable disabled app autostart.
When replacing an already enabled native package startup, first verify the
managed link, then disable only that native startup entry. Leave disabled or
absent native startup alone. Foreign Startup links are refused. The monitoring
task and app-start intent are separate; uninstalling the monitoring task does
not delete the source or change independently configured app startup.

## Recovery rules

| Observation | Result |
| --- | --- |
| Codex is healthy or idle | Do nothing |
| Desktop and app-server are absent | Launch Codex, then allow five minutes of startup grace |
| Desktop exists but app-server is absent | Restart after five minutes and three consecutive checks |
| A live direct app-server child uses an unrecognized or unreadable executable path | Report a manual condition; do not close or restart Codex |
| `task_started` has no dispatch/model/tool progress | Restart after three minutes if no healthy task would be interrupted |
| A progressed task has no progress | Mark stale after 60 minutes and require five more unchanged minutes |
| A tool call, user-input wait, or approval is outstanding | Protect the task indefinitely |
| Another task remains healthy or active | Do not restart the shared Codex app |
| A single Remote disconnect occurs | Ignore it |
| Remote transport repeatedly fails | Restart only after at least three failures spanning five minutes, with a recent failure and no later success |
| Remote auth, MFA, 401, 403, 409, or disabled enrollment occurs | Report a manual condition; do not restart-loop |
| A Codex SQLite integrity check is not healthy | Report a manual condition; do not recover automatically |

Only lifecycle event metadata is inspected. Authentication and transport
classification is restricted to Codex's dedicated Remote transport logger so
text inside prompts or responses cannot accidentally trigger a recovery.
Rollouts from an older app-server process generation are excluded from active
task decisions.

The app-server path can be the stock package executable, a versioned executable
under `%LOCALAPPDATA%\OpenAI\Codex\bin`, or the exact existing `codex.exe`
selected by `CODEX_CLI_PATH`. Each observation rereads persisted User settings,
then Machine settings, before falling back to the inherited process environment.
This prevents a long-lived Task Scheduler environment from hiding a newly selected
core. An invalid selected override is reported; it does not silently select an
older value. Recognition still requires the current installed Codex main process's
ancestry and the `app-server` command role, rather than an executable name alone.

If an override changes while its previous direct app-server child is still alive,
the old server is `Unknown`, not `Missing`. Automatic recovery pauses with
`UnrecognizedAppServer`, clears the missing-server observation window, and exposes
the owned child's PID/path for inspection. It never treats that path as trusted or
force-stops it. The stop routine also refuses to close Codex while an unknown
direct server exists. Unrelated CLI processes and nested agent tool servers are
not recognized as the desktop server. A genuinely missing server retains the
normal five-minute, three-check recovery rule.

## Recovery sequence and limits

Before recovery, the watchdog records a redacted snapshot containing only
timestamps, the reason, package version, exact Codex process IDs, task IDs,
statuses, and event types. It then:

1. Requests a normal close and waits up to 15 seconds.
2. Force-stops only the current AppX `ChatGPT.exe` and its descended
   `app-server` executable. The latter must use a stock/versioned path or the exact
   valid configured `CODEX_CLI_PATH`; unrelated `codex.exe` processes are excluded.
   Unknown live direct app-server children block the stop operation.
3. Requests normal Enhanced through the canonical installed skill when present.
   Otherwise activates the package through Windows `IApplicationActivationManager`
   using its dynamically discovered App User Model ID. Native activation errors
   remain visible; no `explorer.exe` launch is used as a success substitute.
4. Waits up to 60 seconds for both the desktop root and app-server.
5. Rechecks both SQLite databases and the enabled Remote enrollment.

Automatic launch/restart attempts are limited to three per rolling hour. A
failed recovery creates a ten-minute cooldown. Manual `-Action Restart`
bypasses the automatic decision and rate limit but keeps the exact-process
safety checks and post-restart verification.

## State and diagnostics

Runtime files are stored under `%LOCALAPPDATA%\CodexWatchdog`:

- `state.json` — counters, cooldowns, and task-event fingerprints.
- `watchdog.jsonl` — redacted check/recovery outcomes, rotated at 5 MB.
- `snapshots\` — the newest 50 redacted pre-recovery snapshots.

Read-only `Status` and `Check -WhatIf -Json` report `appServerStatus` as
`Recognized`, `Unknown` or `Missing`, the configured override's source/error,
and unknown direct app-server PID/path evidence. `appServerPresent` counts only
recognized servers; an `Unknown` server is not an automatic restart trigger.

Recovery entries contain a `validation` object. The `started` entry records the
failed trigger rule, including safe evidence such as task ID, event type,
timestamps, observed duration, and configured threshold. The final `succeeded`
or `failed` entry records an individual pass/fail result for package discovery,
desktop process, app-server, both SQLite databases, and Remote enrollment. It
also records the package version before and after recovery so an update during
restart is explicit.

To inspect the newest recovery validation report:

```powershell
Get-Content "$env:LOCALAPPDATA\CodexWatchdog\watchdog.jsonl" |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object event -in 'Launch', 'Restart' |
    Select-Object -Last 2 |
    ConvertTo-Json -Depth 12
```

No prompt text, response text, tool input/output, credential, account ID,
WebSocket URL, or enrollment secret is written by the watchdog.

## Verification and troubleshooting

```powershell
# Run all synthetic lifecycle and policy tests.
$result = Invoke-Pester -Script .\CodexWatchdog.Tests.ps1 -PassThru
$result | Select-Object TotalCount, PassedCount, FailedCount

# Inspect the scheduled task and its latest run result.
Get-ScheduledTask -TaskPath '\Codex\' -TaskName 'Codex Remote Watchdog'
Get-ScheduledTaskInfo -TaskPath '\Codex\' -TaskName 'Codex Remote Watchdog'
```

For a deliberate relaunch test, first finish or pause all important Codex work,
close Codex normally, and wait up to two minutes. Reopen PowerShell and verify
that both processes returned:

```powershell
Get-CimInstance Win32_Process |
    Where-Object Name -in 'ChatGPT.exe', 'codex.exe' |
    Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine
```

This watchdog cannot repair power, sleep, local internet, logged-out-session,
or OpenAI relay-only failures when every local signal still appears healthy.
It does not provide an alternative remote-access path. A genuine recovery can
still show the Codex window briefly because the Codex desktop application is
being relaunched; the once-per-minute watchdog check itself remains invisible.
