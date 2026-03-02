# Incident Report: macOS launchd Silently Misses Near-Future `once` Triggers

**Date**: 2026-03-02
**Platform**: macOS (launchd)
**Severity**: Medium — job silently fails to fire with no error or log output

---

## What Happened

A one-time job (`once 2026-03-02 13:18`) was created at ~13:16. The Mac was awake and the user was active. The job did not fire at 13:18. No logs were written. No error was reported. The scheduler showed the job as `Enabled` and `LOADED` with `LastRun: never`.

**Timeline**:
- `13:16` — Job created with `daily 13:18` schedule
- `13:16` — Schedule updated to `once 2026-03-02 13:18`; launchd plist reloaded
- `13:18` — Expected trigger time; job did not fire
- `13:20` — User noticed no output on Desktop
- `13:21` — Job run manually via `claude-scheduler.sh run`; completed successfully in ~61s

---

## Root Cause

launchd's `StartCalendarInterval` **does not retroactively fire** a trigger that was missed while the agent was being loaded. If the plist is loaded at or after the scheduled time — even by seconds — launchd considers the window closed and will not fire until the next occurrence.

For a `once` job, there is no next occurrence, so the job effectively never runs.

This is a known launchd behavior, not a bug in the scheduler itself, but the current implementation provides no warning when a one-time schedule is set too close to the current time.

---

## Impact

- One-time jobs scheduled less than ~1-2 minutes in the future are at risk of silently not running.
- The user has no indication of failure: no logs, no error, status shows `Enabled`.
- The only recovery path is manual execution via `run`.

---

## Recommended Fixes

### 1. Warn on near-future `once` schedules (Quick Fix)
In `claude-scheduler.sh`, after parsing a `once` schedule, check if the target time is less than 2 minutes away and warn the user:

```bash
# Pseudo-logic in create/update for 'once' schedules
if target_time - now < 120 seconds:
    warn "Warning: scheduled time is less than 2 minutes away. launchd may miss this trigger. Consider using 'run' to execute immediately instead."
```

### 2. Add a catch-up check in the runner (Robust Fix)
When launchd loads a `once` plist, also schedule a short-lived catch-up: if the job's scheduled time is in the past by less than N minutes and `LastRun` is `never`, fire immediately.

### 3. Document in TROUBLESHOOTING.md (Minimum)
Add a macOS section to `TROUBLESHOOTING.md` covering this case so future users and AI agents can diagnose it without manual investigation.

---

## Workaround (for users and AI agents)

If a `once` job was missed:

```bash
bash ~/.claude/scheduler/claude-scheduler.sh run --name <job-name>
```

To avoid the issue, schedule one-time jobs at least 2-3 minutes in the future, or use `run` for immediate execution.

---

## Diagnostics Used

```bash
# Check launchd loaded state and last exit status
launchctl list | grep <job-name>

# Inspect plist configuration
cat ~/Library/LaunchAgents/com.claude-scheduler.<job-name>.plist

# Check for log files
ls ~/.claude/scheduler/logs/<job-name>/
```

A loaded job with exit status `-` (never run) and an empty log directory confirms launchd never attempted to fire the runner.
