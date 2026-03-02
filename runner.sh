#!/bin/bash
# Claude Scheduler Runner - Executes a scheduled Claude Code job on macOS.
#
# Called by launchd to run a Claude Code job defined in a JSON file.
# Handles prompt enhancement, logging, log purging, and status tracking.
#
# Usage: runner.sh <job-name>

set -euo pipefail

JOB_NAME="${1:?Error: Job name is required. Usage: runner.sh <job-name>}"

# --- Path Resolution ---
SCHEDULER_DIR="$HOME/.claude/scheduler"
JOBS_DIR="$SCHEDULER_DIR/jobs"
LOGS_DIR="$SCHEDULER_DIR/logs"
JOB_FILE="$JOBS_DIR/$JOB_NAME.json"
LOG_FILE=""

# --- Helper: Expand ~ to $HOME ---
expand_tilde() {
    local path="$1"
    if [[ -z "$path" ]]; then echo ""; return; fi
    if [[ "$path" == "~" ]]; then echo "$HOME"; return; fi
    if [[ "$path" == "~/"* ]]; then echo "$HOME/${path:2}"; return; fi
    echo "$path"
}

# --- Helper: Write to log file and console ---
write_log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[$timestamp] [$level] $message"
    echo "$line"
    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        echo "$line" >> "$LOG_FILE"
    fi
}

# --- Helper: Atomic JSON write (temp file + rename) ---
write_job_json() {
    local content="$1"
    local path="$2"
    local temp_file="${path}.tmp"
    echo "$content" > "$temp_file"
    mv -f "$temp_file" "$path"
}

# --- Helper: Send failure notification ---
send_failure_notification() {
    local job_name="$1"
    local reason="$2"

    local notify_file="$SCHEDULER_DIR/notify.json"
    if [[ ! -f "$notify_file" ]]; then return 0; fi

    local enabled
    enabled=$(jq -r '.enabled // false' "$notify_file")
    if [[ "$enabled" != "true" ]]; then return 0; fi

    # Check if this failure type should trigger a notification
    local should_notify=false
    if jq -e '.notifyOn[] | select(. == "all-failures" or . == "job-failure")' "$notify_file" >/dev/null 2>&1; then
        should_notify=true
    fi
    if [[ "$should_notify" != "true" ]]; then return 0; fi

    # Build message
    local message="[Claude Scheduler] Job '$job_name' failed: $reason
Re-run: claude-scheduler.sh run --name $job_name"

    # Execute notification command with {{message}} replaced
    local cmd
    cmd=$(jq -r '.command' "$notify_file")

    local cmd_args=()
    while IFS= read -r arg; do
        cmd_args+=("${arg//\{\{message\}\}/$message}")
    done < <(jq -r '.args[]' "$notify_file")

    "$cmd" "${cmd_args[@]}" >/dev/null 2>&1 || true
    write_log "INFO" "Notification sent via $cmd"
}

# --- Error handling via trap ---
cleanup() {
    local exit_code=$?
    # Remove lockfile
    local lock_file="$SCHEDULER_DIR/.lock-$JOB_NAME"
    rm -f "$lock_file"

    if [[ $exit_code -ne 0 ]]; then
        write_log "ERROR" "Runner exited with code $exit_code"
        # Try to update job status on fatal error
        if [[ -f "$JOB_FILE" ]] && command -v jq &>/dev/null; then
            local updated
            updated=$(jq \
                --arg runAt "$(date '+%Y-%m-%dT%H:%M:%S')" \
                --arg runStatus "error:runner-crash-$exit_code" \
                '.lastRunAt = $runAt | .lastRunStatus = $runStatus' \
                "$JOB_FILE" 2>/dev/null) && \
            write_job_json "$updated" "$JOB_FILE" || true
        fi
        send_failure_notification "$JOB_NAME" "Runner crashed with exit code $exit_code" || true
    fi

    # --- Finally: regenerate plist for next occurrence (daily/weekly only) ---
    # Runs regardless of job success or failure — like a finally block.
    # Spawned as a background process so it starts after this runner fully exits,
    # allowing launchd to cleanly deregister the current service before the
    # scheduler script attempts bootout + bootstrap for the next interval.
    local sched_for_regen=""
    if [[ -f "$JOB_FILE" ]] && command -v jq &>/dev/null; then
        sched_for_regen=$(jq -r '.schedule // ""' "$JOB_FILE" 2>/dev/null || true)
    fi
    if echo "$sched_for_regen" | grep -qE '^(daily|weekly) '; then
        local scheduler_script="$SCHEDULER_DIR/claude-scheduler.sh"
        if [[ -f "$scheduler_script" ]]; then
            write_log "INFO" "Queuing plist regeneration for next occurrence of: $sched_for_regen"
            # sleep 5: gives launchd time to process this runner's exit before
            # the scheduler script calls bootout + bootstrap on the same label.
            (sleep 5 && bash "$scheduler_script" _regen_plist --name "$JOB_NAME" >> "$LOG_FILE" 2>&1) &
            disown $! 2>/dev/null || true
        else
            write_log "ERROR" "Cannot regenerate plist: scheduler not found at $scheduler_script"
        fi
    fi
}
trap cleanup EXIT

# --- Main Execution ---

# 1. Validate job file exists
if [[ ! -f "$JOB_FILE" ]]; then
    echo "Error: Job file not found: $JOB_FILE" >&2
    exit 1
fi

# 2. Read and validate job definition
job_name=$(jq -r '.name // empty' "$JOB_FILE")
job_prompt=$(jq -r '.prompt // empty' "$JOB_FILE")

if [[ -z "$job_name" ]]; then
    echo "Error: Job missing required field: name" >&2
    exit 1
fi
if [[ -z "$job_prompt" ]]; then
    echo "Error: Job missing required field: prompt" >&2
    exit 1
fi

# 3. Check enabled flag
job_enabled=$(jq -r '.enabled // true' "$JOB_FILE")
if [[ "$job_enabled" == "false" ]]; then
    echo "Job '$JOB_NAME' is disabled. Skipping."
    exit 0
fi

# 3b. One-time schedule guard: skip if already ran successfully
job_schedule=$(jq -r '.schedule // ""' "$JOB_FILE")
job_last_status=$(jq -r '.lastRunStatus // ""' "$JOB_FILE")
if echo "$job_schedule" | grep -qE '^once ' && [[ "$job_last_status" == "success" ]]; then
    echo "Job '$JOB_NAME' is a one-time job that already ran successfully. Skipping."
    exit 0
fi

# 4. Set up logging
job_log_dir="$LOGS_DIR/$JOB_NAME"
mkdir -p "$job_log_dir"
timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
LOG_FILE="$job_log_dir/$timestamp.log"
touch "$LOG_FILE"

write_log "INFO" "=== Claude Scheduler Runner ==="
write_log "INFO" "Job: $JOB_NAME"
write_log "INFO" "Started: $(date '+%Y-%m-%d %H:%M:%S')"
write_log "INFO" "Log file: $LOG_FILE"

# 5. Lockfile to prevent concurrent execution
LOCK_FILE="$SCHEDULER_DIR/.lock-$JOB_NAME"
if [[ -f "$LOCK_FILE" ]]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
        write_log "INFO" "Job is already running (PID $lock_pid). Skipping."
        exit 0
    fi
    write_log "INFO" "Stale lockfile found (PID $lock_pid not running). Removing."
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

# 6. Purge old logs
retention_days=$(jq -r '.logRetentionDays // 30' "$JOB_FILE")
purged_count=0
if [[ -d "$job_log_dir" ]]; then
    while IFS= read -r old_log; do
        rm -f "$old_log"
        purged_count=$((purged_count + 1))
    done < <(find "$job_log_dir" -name "*.log" -mtime +"$retention_days" 2>/dev/null)
    if [[ $purged_count -gt 0 ]]; then
        write_log "INFO" "Purged $purged_count log files older than $retention_days days"
    fi
fi

# 7. Ensure PATH includes common locations for claude CLI
# launchd runs in a minimal environment without the user's shell profile
EXTRA_PATHS=(
    "$HOME/.local/bin"
    "/usr/local/bin"
    "/opt/homebrew/bin"
    "$HOME/.npm-global/bin"
    "$HOME/bin"
)

# Add Claude desktop app path if present (version number in path changes)
claude_app_dir=$(find "$HOME/Library/Application Support/Claude/claude-code" -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)
if [[ -n "$claude_app_dir" ]]; then
    EXTRA_PATHS+=("$claude_app_dir")
fi

# Add NVM-managed Node path if present
if [[ -d "$HOME/.nvm/versions/node" ]]; then
    nvm_node_dir=$(find "$HOME/.nvm/versions/node" -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)
    if [[ -n "$nvm_node_dir" && -d "$nvm_node_dir/bin" ]]; then
        EXTRA_PATHS+=("$nvm_node_dir/bin")
    fi
fi

for dir in "${EXTRA_PATHS[@]}"; do
    if [[ -d "$dir" ]] && [[ ":$PATH:" != *":$dir:"* ]]; then
        PATH="$dir:$PATH"
    fi
done
export PATH

# Unset CLAUDECODE to allow running from within a Claude Code session (manual run)
unset CLAUDECODE 2>/dev/null || true

# Source NVM if available (for nvm-managed Node installations)
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    source "$NVM_DIR/nvm.sh" 2>/dev/null || true
fi

# 8. Verify claude CLI is available
if ! command -v claude &>/dev/null; then
    write_log "ERROR" "Claude CLI not found. Ensure it is installed and on PATH."
    write_log "ERROR" "Searched PATH: $PATH"
    # Update job JSON with error status
    updated=$(jq \
        --arg runAt "$(date '+%Y-%m-%dT%H:%M:%S')" \
        '.lastRunAt = $runAt | .lastRunStatus = "error:claude-not-found"' \
        "$JOB_FILE")
    write_job_json "$updated" "$JOB_FILE"
    exit 1
fi

write_log "INFO" "Claude CLI: $(which claude)"

# 9. Resolve working directory
work_dir=$(jq -r '.workingDirectory // "~"' "$JOB_FILE")
work_dir=$(expand_tilde "$work_dir")

if [[ ! -d "$work_dir" ]]; then
    write_log "ERROR" "Working directory not found: $work_dir. Falling back to home directory."
    work_dir="$HOME"
fi

write_log "INFO" "Working directory: $work_dir"

# 10. Build autonomy system prompt
job_description=$(jq -r '.description // ""' "$JOB_FILE")
autonomy_prompt="AUTONOMOUS SCHEDULED TASK MODE:
- You are running as a scheduled background task with no human present
- No one is available to answer questions or approve permissions
- Make reasonable decisions independently
- If a step fails, log the error clearly and continue with remaining steps
- Summarize what you accomplished and any issues encountered
- Do NOT use AskUserQuestion or any interactive features
- Current time: $(date '+%Y-%m-%d %H:%M:%S')
- Job: $job_name - $job_description"

append_system_prompt=$(jq -r '.appendSystemPrompt // empty' "$JOB_FILE")
if [[ -n "$append_system_prompt" ]]; then
    autonomy_prompt="$autonomy_prompt

$append_system_prompt"
fi

# 11. Build Claude CLI arguments array
cli_args=()
cli_args+=("-p" "$job_prompt")
cli_args+=("--dangerously-skip-permissions")
cli_args+=("--output-format" "json")
cli_args+=("--append-system-prompt" "$autonomy_prompt")
cli_args+=("--verbose")

# Optional: model
model=$(jq -r '.model // empty' "$JOB_FILE")
if [[ -n "$model" ]]; then
    cli_args+=("--model" "$model")
fi

# Optional: effort
effort=$(jq -r '.effort // empty' "$JOB_FILE")
if [[ -n "$effort" ]]; then
    cli_args+=("--effort" "$effort")
fi

# Optional: max budget
max_budget=$(jq -r '.maxBudgetUsd // empty' "$JOB_FILE")
if [[ -n "$max_budget" ]]; then
    cli_args+=("--max-budget-usd" "$max_budget")
fi

# Optional: allowed tools
allowed_tools=$(jq -r '.allowedTools // [] | if length > 0 then join(",") else empty end' "$JOB_FILE")
if [[ -n "$allowed_tools" ]]; then
    cli_args+=("--allowedTools" "$allowed_tools")
fi

# Optional: disallowed tools
disallowed_tools=$(jq -r '.disallowedTools // [] | if length > 0 then join(",") else empty end' "$JOB_FILE")
if [[ -n "$disallowed_tools" ]]; then
    cli_args+=("--disallowedTools" "$disallowed_tools")
fi

# Optional: no session persistence (default true)
no_session=$(jq -r '.noSessionPersistence // true' "$JOB_FILE")
if [[ "$no_session" != "false" ]]; then
    cli_args+=("--no-session-persistence")
fi

write_log "INFO" "Prompt: $job_prompt"
write_log "INFO" "Model: ${model:-default}"
if [[ -n "$max_budget" ]]; then write_log "INFO" "Budget: \$$max_budget"; fi
if [[ -n "$effort" ]]; then write_log "INFO" "Effort: $effort"; fi
write_log "INFO" "Executing Claude CLI..."
write_log "INFO" "---"

# 12. Execute Claude CLI
start_time=$(date '+%s')

cd "$work_dir"
set +e
output=$(claude "${cli_args[@]}" 2>&1)
exit_code=$?
set -e

end_time=$(date '+%s')
duration=$((end_time - start_time))

# Write claude output to log
write_log "INFO" "---"
write_log "INFO" "Claude CLI output:"
echo "$output" >> "$LOG_FILE"

# 13. Try to parse JSON result for summary
result_preview=$(echo "$output" | jq -r '.result // empty' 2>/dev/null | head -c 200) || true
cost=$(echo "$output" | jq -r '.cost_usd // empty' 2>/dev/null) || true
if [[ -n "$result_preview" ]]; then
    write_log "INFO" "Result preview: ${result_preview}..."
fi
if [[ -n "$cost" ]]; then
    write_log "INFO" "Cost: \$$cost"
fi

# 14. Update job status
status_value="success"
if [[ $exit_code -ne 0 ]]; then
    status_value="failed:$exit_code"
fi

updated=$(jq \
    --arg runAt "$(date '+%Y-%m-%dT%H:%M:%S')" \
    --arg runStatus "$status_value" \
    --argjson duration "$duration" \
    '.lastRunAt = $runAt | .lastRunStatus = $runStatus | .lastRunDurationSec = $duration' \
    "$JOB_FILE")
write_job_json "$updated" "$JOB_FILE"

write_log "INFO" "---"
write_log "INFO" "Job completed: status=$status_value, duration=${duration}s"

# 15. One-time schedule: auto-disable after execution
if echo "$job_schedule" | grep -qE '^once '; then
    write_log "INFO" "One-time schedule detected. Disabling job after execution."
    updated=$(jq '.enabled = false' "$JOB_FILE")
    write_job_json "$updated" "$JOB_FILE"
    # Unload from launchd
    label="com.claude-scheduler.${JOB_NAME}"
    uid=$(id -u)
    launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
    write_log "INFO" "Job '$JOB_NAME' has been disabled (one-time execution complete)."
fi

# 16. Send notification for job failures
if [[ $exit_code -ne 0 ]]; then
    send_failure_notification "$JOB_NAME" "Exit code $exit_code. Check logs for details." || true
fi

exit $exit_code
