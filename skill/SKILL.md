---
name: claude-scheduler
description: >
  Manages scheduled Claude Code jobs on Windows using Task Scheduler.
  Use this skill when the user wants to: create a scheduled task for Claude,
  list their scheduled jobs, enable or disable a job, run a job manually,
  view job logs, delete a scheduled job, check job status, or manage log
  retention. Also triggers for: "schedule this to run daily", "set up a
  cron job for Claude", "automate this prompt", "run this every morning",
  "what jobs are scheduled", "show me the logs", "pause my daily scan",
  "list my scheduled tasks", "run my job now".
argument-hint: [action and details]
allowed-tools: Bash, Read
---

# Claude Scheduler Management

## Context

You are managing scheduled Claude Code jobs via the `claude-scheduler.ps1`
PowerShell CLI. The management script is installed at:

```
$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1
```

All commands run via PowerShell. Use the Bash tool like:
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" <command> [args]
```

## Commands Reference

| Command | Syntax | Purpose |
|---------|--------|---------|
| create | `create -Name <n> -Prompt <p> -Schedule <s> [opts]` | Create a new scheduled job |
| update | `update -Name <n> [-Schedule <s>] [-Prompt <p>] [opts]` | Update an existing job |
| list | `list` | Show all jobs with status |
| enable | `enable -Name <n>` | Re-enable a disabled job |
| disable | `disable -Name <n>` | Temporarily pause a job |
| run | `run -Name <n>` | Execute a job immediately |
| delete | `delete -Name <n> [-KeepLogs]` | Permanently remove a job and its logs |
| logs | `logs -Name <n> [-Tail N]` | View latest log output |
| purge-logs | `purge-logs [-Days N] [-Name <n>]` | Delete old log files |
| status | `status -Name <n>` | Detailed job information |
| setup-notify | `setup-notify -NotifyCommand <cmd> -NotifyArgs <args>` | Configure failure notifications |
| test-notify | `test-notify` | Send a test notification |

### Create options

| Parameter | Default | Description |
|-----------|---------|-------------|
| -Name | (required) | Job name: letters, numbers, hyphens, underscores only |
| -Prompt | (required) | The prompt Claude will execute |
| -Schedule | (required) | When to run (see schedule syntax below) |
| -Description | '' | Human-readable description |
| -Model | sonnet | Claude model: sonnet, opus, haiku |
| -MaxBudget | (none) | Max USD per run. Only passed if explicitly set |
| -Effort | '' | low, medium, or high |
| -WorkDir | ~ | Working directory (~ = home) |
| -AllowedTools | [] | Restrict to specific tools |
| -DisallowedTools | [] | Block specific tools |
| -LogRetention | 30 | Days to keep logs |
| -AppendSystemPrompt | null | Extra system prompt text |

### Model guidance

- For simple tasks (fetch + report): `-Model haiku` — fast and cheap
- For moderate tasks: `-Model sonnet` (default) — good balance
- For deep analysis: `-Model opus -Effort high`
- Do NOT set `-MaxBudget` unless the user explicitly asks for a budget cap

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

## How to Handle User Requests

### "Schedule X to run at Y"
1. Extract the prompt (what to run)
2. Extract the schedule (when)
3. Generate a kebab-case job name from the description
4. Choose reasonable defaults: model=sonnet, budget=$5, effort based on complexity
5. Run the create command
6. Show the result and explain how to manage it

### "What jobs do I have?" / "List my scheduled tasks"
Run the `list` command and present results in a readable format.

### "Pause X" / "Stop X temporarily" / "Disable X"
Use `disable`, NOT `delete`. Confirm the action. Explain they can re-enable later.

### "Change the schedule for X" / "Reschedule X" / "Update X"
Use `update -Name <name>` with the fields to change. Only pass fields the user wants changed — all others are preserved.
If the schedule changes and the job was disabled, it will be auto-re-enabled.

```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" update -Name "my-job" -Schedule "weekly Monday 09:00"
```

### "Run this one-time job again"
Use `update` to set a new `once` schedule. This re-activates the job with a fresh trigger.

```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" update -Name "one-off-report" -Schedule "once 2026-04-01 14:00"
```

### "Run X now" / "Execute X"
Use the `run` command. Show output in real-time.

### "Show me the logs for X"
Use `logs -Name <name>`. If they want more lines, add `-Tail N`.

### "Delete X" / "Remove X permanently"
Use `delete`. Warn that this is permanent and removes all logs too.
If they want to keep logs for reference, add `-KeepLogs`.

### "How's X doing?" / "Status of X"
Use the `status` command for detailed info including next run time.

## Example Conversations

**User:** "Schedule a task to fetch HN and summarize it every morning at 9"
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" create -Name "hn-summary" -Prompt "Fetch https://news.ycombinator.com and write a 5-bullet summary of the top stories to ~/claude-scheduler-reports/hn-summary.md. Create the directory if needed." -Schedule "daily 09:00" -Model "haiku" -Description "Daily HN summary report"
```

**User:** "Disable the HN summary job"
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" disable -Name "hn-summary"
```

**User:** "What jobs are running?"
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" list
```

## Failure Notifications

Jobs can send failure notifications to your phone or any service.

### Setup Examples

**WhatsApp (via wacli):**
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" setup-notify -NotifyCommand "wacli" -NotifyArgs "send","--to","<phone>","--message","{{message}}"
```

**ntfy.sh (free push notifications):**
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" setup-notify -NotifyCommand "curl" -NotifyArgs "-d","{{message}}","ntfy.sh/your-topic"
```

**Discord webhook:**
```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "$USERPROFILE/.claude/scheduler/claude-scheduler.ps1" setup-notify -NotifyCommand "curl" -NotifyArgs "-H","Content-Type: application/json","-d","{\"content\":\"{{message}}\"}","https://discord.com/api/webhooks/..."
```

### NotifyOn events

| Event | Triggers on |
|-------|-------------|
| `job-failure` | Any job exits non-zero |
| `all-failures` | All failure types |

Default: both `job-failure` and `all-failures`.

Use `-NotifyOn` to customize:
```bash
powershell ... setup-notify -NotifyCommand "wacli" -NotifyArgs "..." -NotifyOn "job-failure"
```

### Testing and managing

```bash
# Test notifications
powershell ... test-notify

# Disable without removing config
powershell ... setup-notify -Disable

# Show current config
powershell ... setup-notify
```

### How to handle user requests

**"Notify me when jobs fail" / "Set up WhatsApp notifications"**
1. Ask what notification method they want (WhatsApp/ntfy/Discord/Telegram/etc.)
2. Get the required details (phone number, webhook URL, topic name)
3. Run the `setup-notify` command
4. Run `test-notify` to verify it works

**"Disable notifications" / "Stop sending me alerts"**
Use `setup-notify -Disable`.

## Important Notes

- Job names must be alphanumeric with hyphens/underscores (no spaces)
- Always show the user what command you are about to run before executing
- After creating a job, run `list` to confirm it appears
- `~` in paths is expanded to the user's home directory at runtime
- Jobs run with `--dangerously-skip-permissions` so they work unattended
- The runner automatically purges logs older than the retention period
- Claude Code automatically discovers installed MCP plugins at startup
