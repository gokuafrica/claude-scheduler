---
name: claude-scheduler
description: >
  Manages scheduled Claude Code jobs using launchd on macOS and Task Scheduler
  on Windows. Use this skill when the user wants to: create a scheduled task
  for Claude, list their scheduled jobs, enable or disable a job, run a job
  manually, view job logs, delete a scheduled job, check job status, or manage
  log retention. Also triggers for: "schedule this to run daily", "set up a
  cron job for Claude", "automate this prompt", "run this every morning",
  "what jobs are scheduled", "show me the logs", "pause my daily scan",
  "list my scheduled tasks", "run my job now".
argument-hint: [action and details]
allowed-tools: Bash, Read
---

# Claude Scheduler Management

## Context

You are managing scheduled Claude Code jobs via the `claude-scheduler` CLI.

### Platform Detection

First, determine the platform by checking `uname`:
- **macOS**: `uname` returns "Darwin" — use bash scripts with `--kebab-case` flags
- **Windows**: Running in PowerShell — use PowerShell scripts with `-PascalCase` flags

### macOS

The management script is at:
```
~/.claude/scheduler/claude-scheduler.sh
```

Run commands via:
```bash
bash ~/.claude/scheduler/claude-scheduler.sh <command> [--flag value]
```

### Windows

The management script is at:
```
$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1
```

Run commands via:
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" <command> [args]
```

## Commands Reference

| Command | Purpose |
|---------|---------|
| create | Create a new scheduled job |
| update | Update an existing job |
| list | Show all jobs with status |
| enable | Re-enable a disabled job |
| disable | Temporarily pause a job |
| run | Execute a job immediately |
| delete | Permanently remove a job and its logs |
| logs | View latest log output |
| purge-logs | Delete old log files |
| status | Detailed job information |
| setup-notify | Configure failure notifications |
| test-notify | Send a test notification |

### Parameter Syntax (macOS vs Windows)

| macOS (`--kebab-case`) | Windows (`-PascalCase`) | Description |
|------------------------|------------------------|-------------|
| `--name` | `-Name` | Job name (required for most commands) |
| `--prompt` | `-Prompt` | The prompt Claude will execute |
| `--schedule` | `-Schedule` | When to run (see schedule syntax) |
| `--description` | `-Description` | Human-readable description |
| `--model` | `-Model` | Claude model: sonnet, opus, haiku |
| `--max-budget` | `-MaxBudget` | Max USD per run |
| `--effort` | `-Effort` | low, medium, or high |
| `--work-dir` | `-WorkDir` | Working directory (~ = home) |
| `--allowed-tools` | `-AllowedTools` | Restrict to specific tools (comma-separated) |
| `--disallowed-tools` | `-DisallowedTools` | Block specific tools (comma-separated) |
| `--log-retention` | `-LogRetention` | Days to keep logs (default: 30) |
| `--append-system-prompt` | `-AppendSystemPrompt` | Extra system prompt text |
| `--background` | `-Background` | Run in background |
| `--keep-logs` | `-KeepLogs` | Preserve logs on delete |
| `--tail` | `-Tail` | Lines to show from log |
| `--days` | `-Days` | Days threshold for purge-logs |
| `--notify-command` | `-NotifyCommand` | Notification command |
| `--notify-args` | `-NotifyArgs` | Notification arguments (comma-separated) |
| `--notify-on` | `-NotifyOn` | Event types to notify on |
| `--disable` | `-Disable` | Disable notifications |

### Defaults

| Parameter | Default |
|-----------|---------|
| --model | sonnet |
| --work-dir | ~ |
| --log-retention | 30 |
| --max-budget | (none — only set if user asks) |
| --effort | (none) |

### Model guidance

- For simple tasks (fetch + report): `--model haiku` — fast and cheap
- For moderate tasks: `--model sonnet` (default) — good balance
- For deep analysis: `--model opus --effort high`
- Do NOT set `--max-budget` unless the user explicitly asks for a budget cap

## Schedule Syntax

| Format | Example | Meaning |
|--------|---------|---------|
| `daily HH:MM` | `daily 08:00` | Every day at 8 AM |
| `weekly DAY HH:MM` | `weekly Monday 09:00` | Every Monday at 9 AM |
| `hourly` | `hourly` | Every hour |
| `every Nm` | `every 30m` | Every 30 minutes |
| `every Nh` | `every 4h` | Every 4 hours |
| `once YYYY-MM-DD HH:MM` | `once 2026-03-15 14:00` | One-time |
| `startup` | `startup` | At system boot |
| `logon` | `logon` | At user login |

## Notification Onboarding

**After creating a job**, check if failure notifications are configured:

**macOS:** Check if `~/.claude/scheduler/notify.json` exists.
**Windows:** Check if `$env:USERPROFILE\.claude\scheduler\notify.json` exists.

If `notify.json` does NOT exist, proactively ask the user:

> Would you like to set up failure notifications? If a scheduled job fails, you can get alerted on your phone via:
> - **ntfy.sh** (free, no account needed — just install the ntfy app and pick a topic)
> - **WhatsApp** (via wacli)
> - **Any CLI tool** that can send messages
>
> This is optional but recommended so you know when jobs need attention.

If the user wants notifications, walk them through `setup-notify` and then run `test-notify` to verify.

If they decline, respect that and don't ask again.

## How to Handle User Requests

### "Notify me when jobs fail" / "Set up notifications"
1. Ask what notification method they want (ntfy.sh/WhatsApp/Discord/Telegram/etc.)
2. Get the required details (topic name, phone number, webhook URL)
3. Run the `setup-notify` command with the right arguments
4. Run `test-notify` to verify it works

### "Disable notifications" / "Stop sending me alerts"
Use `setup-notify --disable` (macOS) or `setup-notify -Disable` (Windows).

### "Schedule X to run at Y"
1. Extract the prompt (what to run)
2. Extract the schedule (when)
3. Generate a kebab-case job name from the description
4. Choose reasonable defaults: model=sonnet, effort based on complexity
5. Run the create command
6. Show the result and explain how to manage it
7. **Check for notification onboarding** (see above)

### "What jobs do I have?" / "List my scheduled tasks"
Run the `list` command and present results in a readable format.

### "Pause X" / "Stop X temporarily" / "Disable X"
Use `disable`, NOT `delete`. Confirm the action. Explain they can re-enable later.

### "Change the schedule for X" / "Reschedule X" / "Update X"
Use `update --name <name>` with the fields to change. Only pass fields the user wants changed — all others are preserved.
If the schedule changes and the job was disabled, it will be auto-re-enabled.

**macOS:**
```bash
bash ~/.claude/scheduler/claude-scheduler.sh update --name "my-job" --schedule "weekly Monday 09:00"
```

**Windows:**
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" update -Name "my-job" -Schedule "weekly Monday 09:00"
```

### "Run this one-time job again"
Use `update` to set a new `once` schedule. This re-activates the job with a fresh trigger.

### "Run X now" / "Execute X"
Use the `run` command. Show output in real-time.

### "Show me the logs for X"
Use `logs --name <name>`. If they want more lines, add `--tail N`.

### "Delete X" / "Remove X permanently"
Use `delete`. Warn that this is permanent and removes all logs too.
If they want to keep logs for reference, add `--keep-logs`.

### "How's X doing?" / "Status of X"
Use the `status` command for detailed info including last run time.

## Example Conversations

**User:** "Schedule a task to fetch HN and summarize it every morning at 9"

**macOS:**
```bash
bash ~/.claude/scheduler/claude-scheduler.sh create --name "hn-summary" --prompt "Fetch https://news.ycombinator.com and write a 5-bullet summary of the top stories to ~/claude-scheduler-reports/hn-summary.md. Create the directory if needed." --schedule "daily 09:00" --model "haiku" --description "Daily HN summary report"
```

**Windows:**
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" create -Name "hn-summary" -Prompt "Fetch https://news.ycombinator.com and write a 5-bullet summary of the top stories to ~/claude-scheduler-reports/hn-summary.md. Create the directory if needed." -Schedule "daily 09:00" -Model "haiku" -Description "Daily HN summary report"
```

**User:** "Disable the HN summary job"

**macOS:**
```bash
bash ~/.claude/scheduler/claude-scheduler.sh disable --name "hn-summary"
```

**Windows:**
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" disable -Name "hn-summary"
```

**User:** "What jobs are running?"

**macOS:**
```bash
bash ~/.claude/scheduler/claude-scheduler.sh list
```

**Windows:**
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" list
```

## Failure Notifications

Jobs can send failure notifications to your phone or any service.

### Setup Examples

**ntfy.sh (free push notifications) — macOS:**
```bash
bash ~/.claude/scheduler/claude-scheduler.sh setup-notify --notify-command "curl" --notify-args "-d,{{message}},ntfy.sh/your-topic"
```

**ntfy.sh — Windows:**
```bash
powershell ... setup-notify -NotifyCommand "curl" -NotifyArgs "-d","{{message}}","ntfy.sh/your-topic"
```

**WhatsApp (via wacli) — macOS:**
```bash
bash ~/.claude/scheduler/claude-scheduler.sh setup-notify --notify-command "wacli" --notify-args "send,--to,<phone>,--message,{{message}}"
```

### NotifyOn events

| Event | Triggers on |
|-------|-------------|
| `job-failure` | Any job exits non-zero |
| `all-failures` | All failure types |

Default: both `job-failure` and `all-failures`.

### Testing and managing

**macOS:**
```bash
bash ~/.claude/scheduler/claude-scheduler.sh test-notify
bash ~/.claude/scheduler/claude-scheduler.sh setup-notify --disable
bash ~/.claude/scheduler/claude-scheduler.sh setup-notify
```

**Windows:**
```bash
powershell ... test-notify
powershell ... setup-notify -Disable
powershell ... setup-notify
```

## Important Notes

- Job names must be alphanumeric with hyphens/underscores (no spaces)
- Always show the user what command you are about to run before executing
- After creating a job, run `list` to confirm it appears
- `~` in paths is expanded to the user's home directory at runtime
- Jobs run with `--dangerously-skip-permissions` so they work unattended
- The runner automatically purges logs older than the retention period
- Scheduled jobs run normally when your screen is locked
- Jobs will not run while your computer is asleep, but will catch up when it wakes
- Jobs require you to be logged in (locking the screen is fine; logging out stops jobs)
