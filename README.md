# Claude Scheduler

Schedule Claude Code to run prompts automatically. Think cron jobs for Claude.

Works on macOS and Windows — managed via a Claude Code skill or directly from the terminal.

## What It Does

- Runs any Claude Code prompt on a schedule (daily, weekly, hourly, etc.)
- Automatically enhances prompts for autonomous execution (no human needed)
- Logs every run with timestamps and captures full output
- Purges old logs automatically based on retention settings
- Enable/disable jobs without deleting them
- Run any job manually on demand
- Lists all jobs with status, schedule, and last run info
- Installs a Claude Code skill so you can manage jobs in natural language

## Quick Start

If you already have [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed, just point it at this repo:

```
Clone https://github.com/gokuafrica/claude-scheduler and install it
```

Claude Code will clone the repo, read this README, run the installer, and set everything up for you. That's it — you can then manage scheduled jobs in plain English:

- *"Schedule a task to summarize HN every morning at 9am"*
- *"What jobs do I have scheduled?"*
- *"Pause my daily scan"*

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed (`npm install -g @anthropic-ai/claude-code`)
- Claude Code authenticated (run `claude` once interactively)
- One-time setup: run `claude --dangerously-skip-permissions` interactively to accept the prompt (required for unattended execution)

**Additional requirements by platform:**

| | macOS | Windows |
|---|---|---|
| OS version | 10.15+ | 10/11 |
| Extra dependency | `jq` (`brew install jq`) | PowerShell 5.1+ (built-in) |

## Manual Install

<details>
<summary><strong>macOS</strong></summary>

```bash
git clone https://github.com/gokuafrica/claude-scheduler.git
cd claude-scheduler
bash install.sh
```
</details>

<details>
<summary><strong>Windows</strong></summary>

```powershell
git clone https://github.com/gokuafrica/claude-scheduler.git
cd claude-scheduler
powershell -ExecutionPolicy Bypass -File install.ps1
```
</details>

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

The `/claude-scheduler` skill translates your intent into the right commands and automatically uses the correct platform syntax.

### From the Terminal

<details>
<summary><strong>macOS (bash)</strong></summary>

```bash
# Create a job
bash ~/.claude/scheduler/claude-scheduler.sh create \
  --name "daily-summary" \
  --prompt "Fetch https://news.ycombinator.com and summarize the top stories to ~/reports/hn.md" \
  --schedule "daily 09:00" \
  --model "sonnet" \
  --effort "high"

# Update schedule (also re-activates one-time jobs)
bash ~/.claude/scheduler/claude-scheduler.sh update \
  --name "daily-summary" \
  --schedule "weekly Monday 09:00"

# Update model and effort (keeps everything else)
bash ~/.claude/scheduler/claude-scheduler.sh update \
  --name "daily-summary" \
  --model "opus" --effort "high"

# List all jobs
bash ~/.claude/scheduler/claude-scheduler.sh list

# Run a job now
bash ~/.claude/scheduler/claude-scheduler.sh run --name "daily-summary"

# Pause a job (keeps it, just stops scheduling)
bash ~/.claude/scheduler/claude-scheduler.sh disable --name "daily-summary"

# Resume a job
bash ~/.claude/scheduler/claude-scheduler.sh enable --name "daily-summary"

# View latest log
bash ~/.claude/scheduler/claude-scheduler.sh logs --name "daily-summary"

# Detailed status
bash ~/.claude/scheduler/claude-scheduler.sh status --name "daily-summary"

# Delete a job permanently (removes agent, JSON, and logs)
bash ~/.claude/scheduler/claude-scheduler.sh delete --name "daily-summary"

# Delete but keep logs for reference
bash ~/.claude/scheduler/claude-scheduler.sh delete --name "daily-summary" --keep-logs

# Purge logs older than 7 days
bash ~/.claude/scheduler/claude-scheduler.sh purge-logs --days 7
```

**Tip**: Add an alias to your `~/.zshrc` or `~/.bashrc`:
```bash
alias cs='bash ~/.claude/scheduler/claude-scheduler.sh'
# Then: cs list, cs run --name "daily-summary", etc.
```
</details>

<details>
<summary><strong>Windows (PowerShell)</strong></summary>

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

**Tip**: Add an alias to your PowerShell `$PROFILE`:
```powershell
Set-Alias -Name cs -Value "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1"
# Then: cs list, cs run -Name "daily-summary", etc.
```
</details>

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

All options are available on both platforms. macOS uses `--kebab-case`, Windows uses `-PascalCase`.

| Option | Default | Description |
|--------|---------|-------------|
| `--name` / `-Name` | (required) | Job name (letters, numbers, hyphens, underscores) |
| `--prompt` / `-Prompt` | (required) | The prompt Claude will execute |
| `--schedule` / `-Schedule` | (required) | When to run (see formats above) |
| `--description` / `-Description` | | Human-readable description |
| `--model` / `-Model` | `sonnet` | Claude model: `sonnet`, `opus`, `haiku` |
| `--max-budget` / `-MaxBudget` | | Max USD per run. Only passed to Claude CLI if explicitly set |
| `--effort` / `-Effort` | | `low`, `medium`, or `high` |
| `--work-dir` / `-WorkDir` | `~` | Working directory (`~` = user home) |
| `--log-retention` / `-LogRetention` | `30` | Days to keep log files before auto-purge |
| `--allowed-tools` / `-AllowedTools` | | Restrict to specific tools (e.g., `Read,WebFetch`) |
| `--disallowed-tools` / `-DisallowedTools` | | Block specific tools |
| `--append-system-prompt` / `-AppendSystemPrompt` | | Extra instructions added to the system prompt |

## Failure Notifications

Get notified on your phone when a scheduled job fails.

<details>
<summary><strong>macOS setup</strong></summary>

```bash
# ntfy.sh (free push notifications — no account needed)
bash ~/.claude/scheduler/claude-scheduler.sh setup-notify \
  --notify-command "curl" \
  --notify-args "-d,{{message}},ntfy.sh/your-topic"

# WhatsApp (via wacli)
bash ~/.claude/scheduler/claude-scheduler.sh setup-notify \
  --notify-command "wacli" \
  --notify-args "send,--to,<phone>,--message,{{message}}"

# Test it
bash ~/.claude/scheduler/claude-scheduler.sh test-notify

# Disable
bash ~/.claude/scheduler/claude-scheduler.sh setup-notify --disable
```
</details>

<details>
<summary><strong>Windows setup</strong></summary>

```powershell
# ntfy.sh (free push notifications — no account needed)
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" setup-notify `
  -NotifyCommand "curl" `
  -NotifyArgs "-d","{{message}}","ntfy.sh/your-topic"

# WhatsApp (via wacli)
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" setup-notify `
  -NotifyCommand "wacli" `
  -NotifyArgs "send","--to","<phone>","--message","{{message}}"

# Test it
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" test-notify

# Disable
& "$env:USERPROFILE\.claude\scheduler\claude-scheduler.ps1" setup-notify -Disable
```
</details>

The `{{message}}` placeholder is replaced with a description of which job failed and why. Notifications are stored in `~/.claude/scheduler/notify.json`.

## How It Works

1. **`create`** writes a job definition JSON to `~/.claude/scheduler/jobs/` and registers it with the OS scheduler (launchd on macOS, Task Scheduler on Windows).

2. When the schedule triggers, the **runner** script (`runner.sh` / `runner.ps1`):
   - Reads the job JSON and validates it
   - Purges logs older than the retention period
   - Injects an "autonomous mode" system prompt telling Claude it's running unattended
   - Executes `claude -p` with `--dangerously-skip-permissions`, `--output-format json`, and all configured flags
   - Captures output to a timestamped log file
   - Updates the job JSON with last run time, status, and duration

3. Jobs run under your user account — no admin privileges needed. They run when you're logged in (locking the screen is fine; logging out stops jobs). Jobs won't run during sleep, but catch up when the machine wakes.

## File Locations

| What | Location |
|------|----------|
| Management CLI | `~/.claude/scheduler/claude-scheduler.{sh,ps1}` |
| Runner | `~/.claude/scheduler/runner.{sh,ps1}` |
| Job definitions | `~/.claude/scheduler/jobs/*.json` |
| Logs | `~/.claude/scheduler/logs/{job-name}/*.log` |
| Skill | `~/.claude/skills/claude-scheduler/SKILL.md` |
| OS scheduler entries | `~/Library/LaunchAgents/com.claude-scheduler.*.plist` (macOS) |
| | `\ClaudeScheduler\` in Task Scheduler (Windows) |

## Browser Automation with Scheduled Jobs

Want scheduled jobs that can browse the web, scrape pages, fill forms, or post to social media? Use [claude-browser-agent](https://github.com/gokuafrica/claude-browser-agent) alongside this scheduler.

It gives Claude Code a real browser (via Playwright MCP) with a persistent profile that keeps your login sessions across runs. Once installed, any scheduled job can use browser tools automatically — no extra config needed per job.

```
Schedule a daily job to open https://news.ycombinator.com, read the top 10 stories, and save a summary to ~/reports/hn.md
```

See [CHROME-EXTENSION-RETROSPECTIVE.md](CHROME-EXTENSION-RETROSPECTIVE.md) for why we moved away from the Chrome extension approach.

## Uninstall

<details>
<summary><strong>macOS</strong></summary>

```bash
bash uninstall.sh
```
Removes launchd agents, scripts, and skill. Use `--keep-logs` or `--keep-jobs` to preserve data.
</details>

<details>
<summary><strong>Windows</strong></summary>

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```
Removes Task Scheduler entries, scripts, and skill. Use `-KeepLogs` or `-KeepJobs` to preserve data.
</details>

## License

MIT — free to use, modify, and share.
