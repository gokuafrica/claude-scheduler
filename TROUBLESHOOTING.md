# Troubleshooting Guide

Common issues with Claude Scheduler and how to fix them. If you're an AI agent helping a user, follow the diagnostic steps in order.

---

## Scheduling Issues

### Job never runs / schedule not triggering

#### macOS

**Diagnostic steps**:

1. **Is the launchd agent loaded?**
   ```bash
   launchctl print gui/$(id -u)/com.claude-scheduler.<job-name> 2>&1 | head -5
   ```
   If it says "Could not find service", the plist isn't loaded. Re-enable the job:
   ```bash
   bash ~/.claude/scheduler/claude-scheduler.sh enable --name "job-name"
   ```

2. **Is the plist file present?**
   ```bash
   ls ~/Library/LaunchAgents/com.claude-scheduler.*.plist
   ```
   If missing, the job may need to be re-created.

3. **Is the computer awake at trigger time?**
   Jobs only fire when the user is logged in and the system is awake. If the computer is asleep at 9:00 AM, a `daily 09:00` job won't fire until the system wakes. The login hook will recalculate the schedule on next login.

4. **Was the system rebooted?**
   Daily/weekly jobs use `StartInterval` which is relative to plist load time. The login hook (`com.user.claude-scheduler.login-regen`) should recalculate all intervals on login. Verify it's loaded:
   ```bash
   launchctl print gui/$(id -u)/com.user.claude-scheduler.login-regen 2>&1 | head -3
   ```

5. **Check launchd stderr logs**:
   ```bash
   cat ~/Library/LaunchAgents/com.claude-scheduler.<job-name>.plist | grep -A1 StandardErrorPath
   # Then read that file
   ```

#### Windows

**Diagnostic steps**:

1. **Is the Task Scheduler entry registered?**
   ```powershell
   Get-ScheduledTask -TaskPath '\ClaudeScheduler\' | Format-Table TaskName, State
   ```
   If the job is missing, re-create it. If it shows `Disabled`, enable it:
   ```powershell
   & "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" enable -Name "job-name"
   ```

2. **Is the computer awake at trigger time?**
   Jobs set with `-LogonType Interactive` only fire when the user is logged in. If the computer is asleep at 9:00 AM, a `daily 09:00` job won't fire. The `StartWhenAvailable` setting causes it to run when the computer wakes up, but only within ~2 hours of the trigger time.

3. **Check Task Scheduler history**:
   Open Task Scheduler UI (`taskschd.msc`) > navigate to `\ClaudeScheduler\` > right-click the task > "Properties" > "History" tab. Look for error codes.

4. **Common error codes**:
   - `0x1` (1): Task ran but the script returned non-zero exit code — check the job logs
   - `0x41301`: Task is currently running (another instance)
   - `0x41303`: Task has not been started (trigger hasn't fired yet)
   - `0x800710E0`: The operator or administrator has refused the request — usually a permissions issue

---

## Claude CLI Issues

### "Claude CLI not found" during job execution

#### macOS

Launchd runs with a minimal environment. The runner adds common paths (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, etc.) and searches for the Claude desktop app, but if Claude is installed in an unusual location:

```bash
which claude
```

Ensure that directory is in a standard location the runner checks, or add it to the PATH in your shell profile.

#### Windows

The Task Scheduler environment may not have the same PATH as your interactive shell.

**Fix**: The runner automatically adds npm and Node.js directories to PATH. If Claude is installed elsewhere, check:
```powershell
where.exe claude
```
And ensure that directory is in the system PATH (not just the user's shell profile).

### "skipDangerousModePermissionPrompt" warning

Scheduled jobs run with `--dangerously-skip-permissions` which requires accepting a one-time prompt. Run Claude interactively once:
```
claude --dangerously-skip-permissions
```
Type "yes" when prompted. This only needs to be done once per machine.

---

## Job Definition Issues

### Job JSON exists but scheduler entry is missing

This happens when launchd agents (macOS) or Task Scheduler entries (Windows) are removed outside of claude-scheduler.

**Fix**: Delete and re-create the job:

**macOS:**
```bash
rm ~/.claude/scheduler/jobs/job-name.json
bash ~/.claude/scheduler/claude-scheduler.sh create --name "job-name" --prompt "..." --schedule "..."
```

**Windows:**
```powershell
Remove-Item "$env:USERPROFILE\.claude\scheduler\jobs\job-name.json"
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" create -Name "job-name" -Prompt "..." -Schedule "..."
```

### Job shows "failed" but no useful error in logs

1. Check the full log file:

   **macOS:**
   ```bash
   bash ~/.claude/scheduler/claude-scheduler.sh logs --name "job-name" --tail 200
   ```
   **Windows:**
   ```powershell
   & "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" logs -Name "job-name" -Tail 200
   ```

2. Try running the job manually to see real-time output:

   **macOS:**
   ```bash
   bash ~/.claude/scheduler/claude-scheduler.sh run --name "job-name"
   ```
   **Windows:**
   ```powershell
   & "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" run -Name "job-name"
   ```

3. Check the job JSON for the `lastRunStatus` field:

   **macOS:**
   ```bash
   jq '.lastRunStatus, .lastRunAt, .lastRunDurationSec' ~/.claude/scheduler/jobs/job-name.json
   ```
   **Windows:**
   ```powershell
   Get-Content "$env:USERPROFILE\.claude\scheduler\jobs\job-name.json" | ConvertFrom-Json | Select-Object lastRunStatus, lastRunAt, lastRunDurationSec
   ```

---

## Notification Issues

### Notifications not being sent

**Diagnostic steps**:

1. **Is notification config present and enabled?**

   **macOS:**
   ```bash
   cat ~/.claude/scheduler/notify.json
   ```
   **Windows:**
   ```powershell
   Get-Content "$env:USERPROFILE\.claude\scheduler\notify.json"
   ```
   Check that `enabled` is `true` and `notifyOn` includes the relevant event type.

2. **Test manually**:

   **macOS:**
   ```bash
   bash ~/.claude/scheduler/claude-scheduler.sh test-notify
   ```
   **Windows:**
   ```powershell
   & "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" test-notify
   ```

3. **Check the job logs**: Search for "Notification sent" or "Failed to send notification" in the latest log.

4. **Common issues**:
   - `{{message}}` placeholder missing from args — the notification fires but with no message content
   - Command path wrong or not on PATH — use the full absolute path to the notification binary
   - Args array was flattened to a single string — re-run `setup-notify` ensuring each argument is comma-separated

### WhatsApp (wacli) notification fails

- Ensure wacli is authenticated: run `wacli login` if needed
- Ensure the phone number includes country code (e.g., `918584946413` for India)
- Test wacli directly: `wacli send text --to PHONE --message "test"`

---

## Installation Issues

### Installer reports "MISSING" for a file

The installer expects the scripts and `skill/SKILL.md` in the same directory. Ensure you cloned the full repository:

**macOS:**
```bash
git clone https://github.com/gokuafrica/claude-scheduler.git
cd claude-scheduler
bash install.sh
```

**Windows:**
```powershell
git clone https://github.com/gokuafrica/claude-scheduler.git
cd claude-scheduler
powershell -ExecutionPolicy Bypass -File install.ps1
```

### Installed files are out of date

Re-run the installer with the force flag to overwrite all files:

**macOS:**
```bash
bash install.sh --force
```

**Windows:**
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Force
```

---

## Quick Reference

| Symptom | Likely cause | Quick fix |
|---------|-------------|-----------|
| Job never runs | Computer asleep at trigger time or agent/task disabled | Check scheduler state, enable job |
| `error:claude-not-found` | PATH not set in launchd/Task Scheduler context | Check system PATH includes Claude CLI |
| `failed:1` | Claude CLI ran but returned error | Check logs for Claude's error output |
| No notification received | notify.json missing or disabled | Run `test-notify` to diagnose |
| Job JSON exists but not in scheduler | Entry deleted outside claude-scheduler | Delete JSON and re-create job |
| `skipDangerousModePermissionPrompt` warning | One-time acceptance not done | Run `claude --dangerously-skip-permissions` once |
| Jobs wrong time after reboot (macOS) | Login hook not regenerating plists | Check `com.user.claude-scheduler.login-regen` is loaded |
