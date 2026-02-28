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
| list | `list` | Show all jobs with status |
| enable | `enable -Name <n>` | Re-enable a disabled job |
| disable | `disable -Name <n>` | Temporarily pause a job |
| run | `run -Name <n>` | Execute a job immediately |
| delete | `delete -Name <n>` | Permanently remove a job |
| logs | `logs -Name <n> [-Tail N]` | View latest log output |
| purge-logs | `purge-logs [-Days N] [-Name <n>]` | Delete old log files |
| status | `status -Name <n>` | Detailed job information |

### Create options

| Parameter | Default | Description |
|-----------|---------|-------------|
| -Name | (required) | Job name: letters, numbers, hyphens, underscores only |
| -Prompt | (required) | The prompt Claude will execute |
| -Schedule | (required) | When to run (see schedule syntax below) |
| -Description | '' | Human-readable description |
| -Model | sonnet | Claude model: sonnet, opus, haiku, or full model ID |
| -MaxBudget | (none) | Max USD per run. Only passed if explicitly set |
| -Effort | '' | low, medium, or high — controls thinking depth |
| -MaxThinkingTokens | (none) | Cap thinking tokens (e.g., 8000). Set via env var at runtime |
| -WorkDir | ~ | Working directory (~ = home) |
| -AllowedTools | [] | Restrict to specific tools |
| -DisallowedTools | [] | Block specific tools |
| -LogRetention | 30 | Days to keep logs |
| -McpConfig | null | Path to MCP config JSON |
| -AppendSystemPrompt | null | Extra system prompt text |

### Model and thinking guidance

- For simple tasks (fetch + report): `-Model haiku` — fast and cheap
- For moderate tasks: `-Model sonnet` (default) — good balance
- For deep analysis: `-Model sonnet -Effort high` or `-Model opus -Effort high`
- Thinking is automatic on Sonnet/Opus. Use `-Effort high` for more thinking
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

### "Run X now" / "Execute X"
Use the `run` command. Show output in real-time.

### "Show me the logs for X"
Use `logs -Name <name>`. If they want more lines, add `-Tail N`.

### "Delete X" / "Remove X permanently"
Use `delete`. Warn that this is permanent (but logs are preserved).

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

## Important Notes

- Job names must be alphanumeric with hyphens/underscores (no spaces)
- Always show the user what command you are about to run before executing
- After creating a job, run `list` to confirm it appears
- `~` in paths is expanded to the user's home directory at runtime
- Jobs run with `--dangerously-skip-permissions` so they work unattended
- The runner automatically purges logs older than the retention period
- If a job needs browser/MCP tools, the user must provide an MCP config
