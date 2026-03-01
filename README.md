# Claude Scheduler

Schedule Claude Code CLI to run prompts automatically using Windows Task Scheduler. Think cron jobs for Claude.

## What it does

- Runs any Claude Code prompt on a schedule (daily, weekly, hourly, etc.)
- Automatically enhances prompts for autonomous execution (no human needed)
- Logs every run with timestamps and captures full output
- Purges old logs automatically based on retention settings
- Enable/disable jobs without deleting them
- Run any job manually on demand
- Lists all jobs with status, schedule, and last run info
- Installs a Claude Code skill so you can manage jobs in natural language

## Quick Start (easiest way)

If you already have [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed, just point it at this repo:

```
Clone https://github.com/gokuafrica/claude-scheduler and install it
```

Claude Code will clone the repo, read this README, run the installer, and set everything up for you. That's it — you can then manage scheduled jobs in plain English:

- *"Schedule a task to summarize HN every morning at 9am"*
- *"What jobs do I have scheduled?"*
- *"Pause my daily scan"*

## Prerequisites

- Windows 10/11
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed (`npm install -g @anthropic-ai/claude-code`)
- Claude Code authenticated (run `claude` once interactively)
- PowerShell 5.1+ (included with Windows 10/11)
- One-time setup: run `claude --dangerously-skip-permissions` interactively to accept the prompt (required for unattended execution)

## Manual Install

```powershell
git clone https://github.com/gokuafrica/claude-scheduler.git
cd claude-scheduler
powershell -ExecutionPolicy Bypass -File install.ps1
```

This copies the scheduler scripts to `~/.claude/scheduler/` and installs the Claude Code skill to `~/.claude/skills/claude-scheduler/`. Existing jobs and logs are preserved on reinstall.

## Usage

### From Claude Code (recommended)

Once installed, just talk to Claude:

| You say | What happens |
|---------|-------------|
| "Schedule a task to summarize HN daily at 9am" | Creates a scheduled job |
| "What jobs do I have?" | Lists all jobs with status |
| "Run my summary job now" | Executes immediately |
| "Pause the daily scan" | Disables without deleting |
| "Change my job to run weekly" | Updates the schedule |
| "Show me the logs for my-job" | Displays latest run output |
| "Delete the test job" | Removes permanently (job + logs) |

The `/claude-scheduler` skill translates your intent into the right commands.

### From PowerShell

```powershell
# Create a job
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" create `
  -Name "daily-summary" `
  -Prompt "Fetch https://news.ycombinator.com and summarize the top stories to ~/reports/hn.md" `
  -Schedule "daily 09:00" `
  -Model "sonnet" `
  -Effort "high"

# Update schedule (also re-activates one-time jobs)
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" update `
  -Name "daily-summary" `
  -Schedule "weekly Monday 09:00"

# Update model and effort (keeps everything else)
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" update `
  -Name "daily-summary" `
  -Model "opus" -Effort "high"

# List all jobs
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" list

# Run a job now
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" run -Name "daily-summary"

# Pause a job (keeps it, just stops scheduling)
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" disable -Name "daily-summary"

# Resume a job
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" enable -Name "daily-summary"

# View latest log
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" logs -Name "daily-summary"

# Detailed status
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" status -Name "daily-summary"

# Delete a job permanently (removes task, JSON, and logs)
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" delete -Name "daily-summary"

# Delete but keep logs for reference
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" delete -Name "daily-summary" -KeepLogs

# Purge logs older than 7 days
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" purge-logs -Days 7
```

**Tip**: Add an alias to your PowerShell `$PROFILE` for convenience:
```powershell
Set-Alias -Name cs -Value "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1"
# Then: cs list, cs run -Name "daily-summary", etc.
```

## Schedule Formats

| Format | Example | Meaning |
|--------|---------|---------|
| `daily HH:MM` | `daily 08:00` | Every day at 8 AM |
| `weekly DAY HH:MM` | `weekly Monday 09:00` | Every Monday at 9 AM |
| `hourly` | `hourly` | Every hour |
| `every Nm` | `every 30m` | Every 30 minutes |
| `every Nh` | `every 4h` | Every 4 hours |
| `once YYYY-MM-DD HH:MM` | `once 2026-03-15 14:00` | One-time execution |
| `startup` | `startup` | At system boot |
| `logon` | `logon` | At user login |

## Job Options

| Option | Default | Description |
|--------|---------|-------------|
| `-Name` | (required) | Job name (letters, numbers, hyphens, underscores) |
| `-Prompt` | (required) | The prompt Claude will execute |
| `-Schedule` | (required) | When to run (see formats above) |
| `-Description` | | Human-readable description |
| `-Model` | `sonnet` | Claude model: `sonnet`, `opus`, `haiku` |
| `-MaxBudget` | | Max USD per run. Only passed to Claude CLI if explicitly set |
| `-Effort` | | `low`, `medium`, or `high` |
| `-WorkDir` | `~` | Working directory (`~` = user home) |
| `-LogRetention` | `30` | Days to keep log files before auto-purge |
| `-AllowedTools` | | Restrict to specific tools (e.g., `Read,WebFetch`) |
| `-DisallowedTools` | | Block specific tools |
| `-McpConfig` | | Path to MCP server config JSON |
| `-AppendSystemPrompt` | | Extra instructions added to the system prompt |

## Failure Notifications

Get notified on your phone when a scheduled job fails.

### Setup

```powershell
# WhatsApp (via wacli)
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" setup-notify `
  -NotifyCommand "wacli" `
  -NotifyArgs "send","--to","<phone>","--message","{{message}}"

# ntfy.sh (free push notifications — no account needed)
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" setup-notify `
  -NotifyCommand "curl" `
  -NotifyArgs "-d","{{message}}","ntfy.sh/your-topic"

# Test it
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" test-notify

# Disable
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" setup-notify -Disable
```

The `{{message}}` placeholder is replaced with a description of which job failed and why. Notifications are stored in `~/.claude/scheduler/notify.json`.

## How It Works

1. **`create`** writes a job definition JSON to `~/.claude/scheduler/jobs/` and registers a Windows Task Scheduler entry under `\ClaudeScheduler\`.

2. When the schedule triggers, Task Scheduler runs **`runner.ps1`**, which:
   - Reads the job JSON
   - Purges logs older than the retention period
   - Injects an "autonomous mode" system prompt via `--append-system-prompt` telling Claude it's running unattended
   - Executes `claude -p` with `--dangerously-skip-permissions`, `--output-format json`, and all configured flags
   - Captures output to a timestamped log file
   - Updates the job JSON with last run time, status, and duration

3. Jobs run under your user account with Interactive logon (runs when you're logged in, no password stored).

## File Locations

| What | Where |
|------|-------|
| Management CLI | `~/.claude/scheduler/claude-scheduler.ps1` |
| Runner | `~/.claude/scheduler/runner.ps1` |
| Job definitions | `~/.claude/scheduler/jobs/*.json` |
| Logs | `~/.claude/scheduler/logs/{job-name}/*.log` |
| Skill | `~/.claude/skills/claude-scheduler/SKILL.md` |
| Task Scheduler | `\ClaudeScheduler\` folder in Task Scheduler |

## Chrome Extension Jobs (Not Currently Viable)

We explored scheduling jobs that use the Claude Chrome extension for browser automation (checking dashboards, reading logged-in services, etc.). The Chrome extension's MCP connection is currently unreliable for unattended use — see [this upstream issue](https://github.com/anthropics/claude-code/issues/26347).

For a detailed account of what we tried and what we learned, see [CHROME-EXTENSION-RETROSPECTIVE.md](CHROME-EXTENSION-RETROSPECTIVE.md).

We'll revisit this when the extension stabilizes.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Removes Task Scheduler entries, scripts, and skill. Use `-KeepLogs` or `-KeepJobs` to preserve data.

## License

MIT — free to use, modify, and share.
