#!/bin/bash
# Claude Scheduler - Manage scheduled Claude Code jobs on macOS.
#
# Create, list, enable, disable, run, delete, and monitor scheduled Claude Code jobs
# that run via macOS launchd (Launch Agents).
#
# Usage:
#   claude-scheduler.sh <command> [options]
#
# Examples:
#   claude-scheduler.sh create --name "daily-summary" --prompt "Summarize HN" --schedule "daily 09:00"
#   claude-scheduler.sh list
#   claude-scheduler.sh run --name "daily-summary"
#   claude-scheduler.sh disable --name "daily-summary"

set -euo pipefail

# --- Paths ---
SCHEDULER_DIR="$HOME/.claude/scheduler"
JOBS_DIR="$SCHEDULER_DIR/jobs"
LOGS_DIR="$SCHEDULER_DIR/logs"
RUNNER_PATH="$SCHEDULER_DIR/runner.sh"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="com.claude-scheduler"

# --- Ensure directories exist ---
for dir in "$SCHEDULER_DIR" "$JOBS_DIR" "$LOGS_DIR"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
done

# --- Parse command ---
COMMAND="${1:-}"
shift || true

# --- Parse flags ---
NAME=""
PROMPT=""
SCHEDULE=""
DESCRIPTION=""
MODEL=""
MAX_BUDGET="-1"
ALLOWED_TOOLS=""
DISALLOWED_TOOLS=""
WORK_DIR=""
EFFORT=""
LOG_RETENTION="30"
APPEND_SYSTEM_PROMPT=""
BACKGROUND=""
TAIL_LINES="50"
DAYS="30"
NOTIFY_COMMAND=""
NOTIFY_ARGS=""
NOTIFY_ON=""
DISABLE_NOTIFY=""
KEEP_LOGS=""

# Track which flags were explicitly provided (for update command)
PROVIDED_FLAGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)       NAME="$2"; PROVIDED_FLAGS+=("name"); shift 2 ;;
        --prompt)     PROMPT="$2"; PROVIDED_FLAGS+=("prompt"); shift 2 ;;
        --schedule)   SCHEDULE="$2"; PROVIDED_FLAGS+=("schedule"); shift 2 ;;
        --description) DESCRIPTION="$2"; PROVIDED_FLAGS+=("description"); shift 2 ;;
        --model)      MODEL="$2"; PROVIDED_FLAGS+=("model"); shift 2 ;;
        --max-budget) MAX_BUDGET="$2"; PROVIDED_FLAGS+=("max-budget"); shift 2 ;;
        --allowed-tools) ALLOWED_TOOLS="$2"; PROVIDED_FLAGS+=("allowed-tools"); shift 2 ;;
        --disallowed-tools) DISALLOWED_TOOLS="$2"; PROVIDED_FLAGS+=("disallowed-tools"); shift 2 ;;
        --work-dir)   WORK_DIR="$2"; PROVIDED_FLAGS+=("work-dir"); shift 2 ;;
        --effort)     EFFORT="$2"; PROVIDED_FLAGS+=("effort"); shift 2 ;;
        --log-retention) LOG_RETENTION="$2"; PROVIDED_FLAGS+=("log-retention"); shift 2 ;;
        --append-system-prompt) APPEND_SYSTEM_PROMPT="$2"; PROVIDED_FLAGS+=("append-system-prompt"); shift 2 ;;
        --background) BACKGROUND="true"; shift ;;
        --tail)       TAIL_LINES="$2"; shift 2 ;;
        --days)       DAYS="$2"; shift 2 ;;
        --notify-command) NOTIFY_COMMAND="$2"; shift 2 ;;
        --notify-args)   NOTIFY_ARGS="$2"; shift 2 ;;
        --notify-on)     NOTIFY_ON="$2"; shift 2 ;;
        --disable)       DISABLE_NOTIFY="true"; shift ;;
        --keep-logs)     KEEP_LOGS="true"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ============================================================
# HELPER FUNCTIONS
# ============================================================

# --- Validate job name ---
validate_job_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "Error: Job name is required. Use --name to specify." >&2
        return 1
    fi
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        echo "Error: Job name must contain only letters, numbers, hyphens, and underscores. Got: '$name'" >&2
        return 1
    fi
    return 0
}

# --- Format relative time ---
format_relative_time() {
    local datetime_str="$1"
    if [[ -z "$datetime_str" || "$datetime_str" == "null" ]]; then
        echo "never"
        return
    fi
    local then_epoch now_epoch diff_seconds
    then_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$datetime_str" "+%s" 2>/dev/null) || {
        echo "$datetime_str"
        return
    }
    now_epoch=$(date "+%s")
    diff_seconds=$((now_epoch - then_epoch))

    if [[ $diff_seconds -lt 60 ]]; then
        echo "just now"
    elif [[ $diff_seconds -lt 3600 ]]; then
        echo "$((diff_seconds / 60))m ago"
    elif [[ $diff_seconds -lt 86400 ]]; then
        echo "$((diff_seconds / 3600))h ago"
    elif [[ $diff_seconds -lt 2592000 ]]; then
        echo "$((diff_seconds / 86400))d ago"
    else
        date -j -f "%Y-%m-%dT%H:%M:%S" "$datetime_str" "+%Y-%m-%d" 2>/dev/null || echo "$datetime_str"
    fi
}

# --- Get launchd label for a job ---
get_label() {
    echo "${LABEL_PREFIX}.${1}"
}

# --- Get plist file path for a job ---
get_plist_path() {
    echo "${LAUNCH_AGENTS_DIR}/$(get_label "$1").plist"
}

# --- Convert day name to launchd weekday number (0=Sun..6=Sat) ---
day_name_to_number() {
    local day
    day=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$day" in
        sunday|sun)    echo 0 ;;
        monday|mon)    echo 1 ;;
        tuesday|tue)   echo 2 ;;
        wednesday|wed) echo 3 ;;
        thursday|thu)  echo 4 ;;
        friday|fri)    echo 5 ;;
        saturday|sat)  echo 6 ;;
        *) echo "Error: Invalid day of week: '$1'. Use Monday, Tuesday, etc." >&2; return 1 ;;
    esac
}

# --- Parse schedule string to plist XML fragment ---
parse_schedule_to_plist_keys() {
    local schedule="$1"

    # daily HH:MM
    if echo "$schedule" | grep -qE '^daily [0-9]{1,2}:[0-9]{2}$'; then
        local hour minute
        hour=$(echo "$schedule" | sed -E 's/^daily ([0-9]{1,2}):[0-9]{2}$/\1/')
        minute=$(echo "$schedule" | sed -E 's/^daily [0-9]{1,2}:([0-9]{2})$/\1/')
        hour=$((10#$hour))
        minute=$((10#$minute))
        cat << EOF
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${hour}</integer>
        <key>Minute</key>
        <integer>${minute}</integer>
    </dict>
EOF
        return 0
    fi

    # weekly DAY HH:MM
    if echo "$schedule" | grep -qiE '^weekly [a-z]+ [0-9]{1,2}:[0-9]{2}$'; then
        local day_name hour minute weekday
        day_name=$(echo "$schedule" | awk '{print $2}')
        hour=$(echo "$schedule" | sed -E 's/^weekly [a-zA-Z]+ ([0-9]{1,2}):[0-9]{2}$/\1/')
        minute=$(echo "$schedule" | sed -E 's/^weekly [a-zA-Z]+ [0-9]{1,2}:([0-9]{2})$/\1/')
        hour=$((10#$hour))
        minute=$((10#$minute))
        weekday=$(day_name_to_number "$day_name") || return 1
        cat << EOF
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>${weekday}</integer>
        <key>Hour</key>
        <integer>${hour}</integer>
        <key>Minute</key>
        <integer>${minute}</integer>
    </dict>
EOF
        return 0
    fi

    # hourly
    if [[ "$schedule" == "hourly" ]]; then
        cat << EOF
    <key>StartCalendarInterval</key>
    <dict>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
EOF
        return 0
    fi

    # every Nm (minutes)
    if echo "$schedule" | grep -qE '^every [0-9]+m$'; then
        local minutes seconds
        minutes=$(echo "$schedule" | sed -E 's/^every ([0-9]+)m$/\1/')
        if [[ "$minutes" -lt 1 ]]; then
            echo "Error: Interval must be at least 1 minute" >&2
            return 1
        fi
        seconds=$((minutes * 60))
        cat << EOF
    <key>StartInterval</key>
    <integer>${seconds}</integer>
EOF
        return 0
    fi

    # every Nh (hours)
    if echo "$schedule" | grep -qE '^every [0-9]+h$'; then
        local hours seconds
        hours=$(echo "$schedule" | sed -E 's/^every ([0-9]+)h$/\1/')
        if [[ "$hours" -lt 1 ]]; then
            echo "Error: Interval must be at least 1 hour" >&2
            return 1
        fi
        seconds=$((hours * 3600))
        cat << EOF
    <key>StartInterval</key>
    <integer>${seconds}</integer>
EOF
        return 0
    fi

    # once YYYY-MM-DD HH:MM
    if echo "$schedule" | grep -qE '^once [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{1,2}:[0-9]{2}$'; then
        local date_part time_part month day hour minute
        date_part=$(echo "$schedule" | awk '{print $2}')
        time_part=$(echo "$schedule" | awk '{print $3}')
        month=$(echo "$date_part" | cut -d- -f2)
        day=$(echo "$date_part" | cut -d- -f3)
        hour=$(echo "$time_part" | cut -d: -f1)
        minute=$(echo "$time_part" | cut -d: -f2)
        # Strip leading zeros
        month=$((10#$month)); day=$((10#$day))
        hour=$((10#$hour)); minute=$((10#$minute))
        cat << EOF
    <key>StartCalendarInterval</key>
    <dict>
        <key>Month</key>
        <integer>${month}</integer>
        <key>Day</key>
        <integer>${day}</integer>
        <key>Hour</key>
        <integer>${hour}</integer>
        <key>Minute</key>
        <integer>${minute}</integer>
    </dict>
EOF
        return 0
    fi

    # startup / logon
    if [[ "$schedule" == "startup" || "$schedule" == "logon" ]]; then
        cat << EOF
    <key>RunAtLoad</key>
    <true/>
EOF
        return 0
    fi

    # Unknown format
    cat >&2 << 'EOF'
Unknown schedule format.
Supported formats:
  daily HH:MM          - Every day at time (e.g., daily 08:00)
  weekly DAY HH:MM     - Weekly on day (e.g., weekly Monday 09:00)
  hourly               - Every hour
  every Nm             - Every N minutes (e.g., every 30m)
  every Nh             - Every N hours (e.g., every 4h)
  once YYYY-MM-DD HH:MM - One-time (e.g., once 2026-03-15 14:00)
  startup              - At system startup
  logon                - At user logon
EOF
    return 1
}

# --- Generate launchd plist file ---
generate_plist() {
    local job_name="$1"
    local schedule="$2"
    local label
    label=$(get_label "$job_name")
    local plist_path
    plist_path=$(get_plist_path "$job_name")

    local schedule_keys
    schedule_keys=$(parse_schedule_to_plist_keys "$schedule") || return 1

    # Ensure log dir exists for StandardOutPath/StandardErrorPath
    mkdir -p "$LOGS_DIR/$job_name"

    cat > "$plist_path" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${RUNNER_PATH}</string>
        <string>${job_name}</string>
    </array>
${schedule_keys}
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/${job_name}/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/${job_name}/launchd-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>${HOME}/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
PLIST_EOF

    # Validate the generated plist
    if ! plutil -lint "$plist_path" >/dev/null 2>&1; then
        echo "Error: Generated plist is invalid. This is a bug in claude-scheduler." >&2
        plutil -lint "$plist_path" >&2
        rm -f "$plist_path"
        return 1
    fi

    return 0
}

# --- launchd management functions ---
load_job() {
    local job_name="$1"
    local plist_path uid
    plist_path=$(get_plist_path "$job_name")
    uid=$(id -u)
    launchctl bootstrap "gui/${uid}" "$plist_path" 2>/dev/null || true
}

unload_job() {
    local job_name="$1"
    local label uid
    label=$(get_label "$job_name")
    uid=$(id -u)
    launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
}

enable_job() {
    local job_name="$1"
    local label uid
    label=$(get_label "$job_name")
    uid=$(id -u)
    launchctl enable "gui/${uid}/${label}" 2>/dev/null || true
    load_job "$job_name"
}

disable_job() {
    local job_name="$1"
    local label uid
    label=$(get_label "$job_name")
    uid=$(id -u)
    unload_job "$job_name"
    launchctl disable "gui/${uid}/${label}" 2>/dev/null || true
}

kickstart_job() {
    local job_name="$1"
    local label uid
    label=$(get_label "$job_name")
    uid=$(id -u)
    launchctl kickstart "gui/${uid}/${label}" 2>/dev/null
}

# --- Check if a flag was explicitly provided ---
is_flag_provided() {
    local flag="$1"
    local f
    for f in "${PROVIDED_FLAGS[@]+"${PROVIDED_FLAGS[@]}"}"; do
        if [[ "$f" == "$flag" ]]; then
            return 0
        fi
    done
    return 1
}

# --- Check launchd status for a job ---
check_launchd_loaded() {
    local label
    label=$(get_label "$1")
    launchctl list "$label" >/dev/null 2>&1
    return $?
}

# ============================================================
# COMMANDS
# ============================================================

cmd_create() {
    if ! validate_job_name "$NAME"; then exit 1; fi
    if [[ -z "$PROMPT" ]]; then echo "Error: Prompt is required. Use --prompt to specify." >&2; exit 1; fi
    if [[ -z "$SCHEDULE" ]]; then echo "Error: Schedule is required. Use --schedule to specify." >&2; exit 1; fi

    local job_file="$JOBS_DIR/$NAME.json"
    if [[ -f "$job_file" ]]; then
        echo "Error: Job '$NAME' already exists. Delete it first or choose a different name." >&2
        exit 1
    fi

    # Validate schedule before creating anything
    echo "Parsing schedule: $SCHEDULE"
    parse_schedule_to_plist_keys "$SCHEDULE" >/dev/null || exit 1

    # Build max budget value
    local budget_val="null"
    if [[ "$MAX_BUDGET" != "-1" ]]; then
        budget_val="$MAX_BUDGET"
    fi

    # Build job JSON
    jq -n \
        --arg name "$NAME" \
        --arg desc "${DESCRIPTION:-}" \
        --arg prompt "$PROMPT" \
        --arg schedule "$SCHEDULE" \
        --argjson enabled true \
        --argjson maxBudget "$budget_val" \
        --argjson allowedTools "$(echo "${ALLOWED_TOOLS:-}" | jq -R 'if . == "" then [] else split(",") end')" \
        --argjson disallowedTools "$(echo "${DISALLOWED_TOOLS:-}" | jq -R 'if . == "" then [] else split(",") end')" \
        --arg model "${MODEL:-sonnet}" \
        --arg effort "${EFFORT:-}" \
        --arg workDir "${WORK_DIR:-~}" \
        --arg appendSys "${APPEND_SYSTEM_PROMPT:-}" \
        --argjson logRetention "$LOG_RETENTION" \
        --argjson noSession true \
        --arg createdAt "$(date '+%Y-%m-%dT%H:%M:%S')" \
        '{
          schemaVersion: 1, name: $name, description: $desc,
          prompt: $prompt, schedule: $schedule, enabled: $enabled,
          maxBudgetUsd: $maxBudget,
          allowedTools: $allowedTools, disallowedTools: $disallowedTools,
          model: $model, effort: $effort, workingDirectory: $workDir,
          appendSystemPrompt: (if $appendSys == "" then null else $appendSys end),
          logRetentionDays: $logRetention, noSessionPersistence: $noSession,
          createdAt: $createdAt, lastRunAt: null, lastRunStatus: null,
          lastRunDurationSec: null
        }' > "$job_file"

    echo "Created job definition: $job_file"

    # Generate plist and load
    if ! generate_plist "$NAME" "$SCHEDULE"; then
        rm -f "$job_file"
        echo "Error: Failed to create plist. Job not created." >&2
        exit 1
    fi
    load_job "$NAME"

    echo ""
    echo "Job '$NAME' created successfully!"
    echo "  Schedule : $SCHEDULE"
    echo "  Model    : ${MODEL:-sonnet}"
    if [[ "$MAX_BUDGET" != "-1" ]]; then echo "  Budget   : \$$MAX_BUDGET"; fi
    if [[ -n "${EFFORT:-}" ]]; then echo "  Effort   : $EFFORT"; fi
    echo "  Run now  : claude-scheduler.sh run --name $NAME"
    echo "  Disable  : claude-scheduler.sh disable --name $NAME"
}

cmd_list() {
    local job_files
    job_files=$(find "$JOBS_DIR" -name "*.json" -maxdepth 1 2>/dev/null | sort)

    if [[ -z "$job_files" ]]; then
        echo "No jobs found."
        echo "Create one with: claude-scheduler.sh create --name <name> --prompt <prompt> --schedule <schedule>"
        exit 0
    fi

    # Print header
    printf "%-20s %-22s %-8s %-8s %-12s %-10s %-8s\n" "Name" "Schedule" "Enabled" "Model" "LastRun" "Status" "Budget"
    printf "%-20s %-22s %-8s %-8s %-12s %-10s %-8s\n" "----" "--------" "-------" "-----" "-------" "------" "------"

    local has_warnings=false
    local warnings=""

    while IFS= read -r job_file; do
        [[ -z "$job_file" ]] && continue
        local name schedule enabled model last_run status budget sync_warning

        name=$(jq -r '.name // "?"' "$job_file")
        schedule=$(jq -r '.schedule // "?"' "$job_file")
        enabled=$(jq -r 'if .enabled then "Yes" else "No" end' "$job_file")
        model=$(jq -r '.model // "-"' "$job_file")
        last_run=$(format_relative_time "$(jq -r '.lastRunAt // ""' "$job_file")")
        status=$(jq -r '.lastRunStatus // "never"' "$job_file")
        budget=$(jq -r 'if .maxBudgetUsd then "$\(.maxBudgetUsd)" else "-" end' "$job_file")

        # Detect sync issues
        sync_warning=""
        local is_loaded=false
        if check_launchd_loaded "$name"; then
            is_loaded=true
        fi

        local json_enabled
        json_enabled=$(jq -r '.enabled // true' "$job_file")

        if [[ "$is_loaded" == "false" ]]; then
            sync_warning=" [!]"
            has_warnings=true
        elif [[ "$json_enabled" == "true" ]] && ! check_launchd_loaded "$name"; then
            sync_warning=" [sync]"
            has_warnings=true
        fi

        printf "%-20s %-22s %-8s %-8s %-12s %-10s %-8s\n" \
            "${name}${sync_warning}" "$schedule" "$enabled" "$model" "$last_run" "$status" "$budget"
    done <<< "$job_files"

    if [[ "$has_warnings" == "true" ]]; then
        echo ""
        echo "Warnings:"
        echo "  [!]    = Job JSON exists but no launchd agent found"
        echo "  [sync] = launchd state doesn't match job JSON enabled state"
    fi
}

cmd_update() {
    if ! validate_job_name "$NAME"; then exit 1; fi
    local job_file="$JOBS_DIR/$NAME.json"
    if [[ ! -f "$job_file" ]]; then
        echo "Error: Job '$NAME' not found. Use 'create' to make a new job." >&2
        exit 1
    fi

    # Check that at least one updatable field was provided
    local has_update=false
    local updatable_flags=("schedule" "prompt" "description" "model" "max-budget" "effort" "work-dir" "allowed-tools" "disallowed-tools" "log-retention" "append-system-prompt")
    for flag in "${updatable_flags[@]}"; do
        if is_flag_provided "$flag"; then
            has_update=true
            break
        fi
    done

    if [[ "$has_update" == "false" ]]; then
        echo "Error: No fields to update. Provide at least one of: --schedule, --prompt, --model, --description, --effort, --max-budget, --work-dir, --allowed-tools, --disallowed-tools, --log-retention, --append-system-prompt" >&2
        exit 1
    fi

    # If schedule is being changed, validate it first
    if is_flag_provided "schedule"; then
        echo "Parsing schedule: $SCHEDULE"
        parse_schedule_to_plist_keys "$SCHEDULE" >/dev/null || exit 1
    fi

    # Load existing job and apply updates
    local job_json changes=()
    job_json=$(cat "$job_file")

    if is_flag_provided "schedule"; then
        local old_schedule
        old_schedule=$(echo "$job_json" | jq -r '.schedule')
        changes+=("Schedule: '$old_schedule' -> '$SCHEDULE'")
        job_json=$(echo "$job_json" | jq --arg v "$SCHEDULE" '.schedule = $v')
    fi
    if is_flag_provided "prompt"; then
        changes+=("Prompt: updated")
        job_json=$(echo "$job_json" | jq --arg v "$PROMPT" '.prompt = $v')
    fi
    if is_flag_provided "description"; then
        changes+=("Description: updated")
        job_json=$(echo "$job_json" | jq --arg v "${DESCRIPTION:-}" '.description = $v')
    fi
    if is_flag_provided "model"; then
        local old_model
        old_model=$(echo "$job_json" | jq -r '.model')
        changes+=("Model: '$old_model' -> '$MODEL'")
        job_json=$(echo "$job_json" | jq --arg v "$MODEL" '.model = $v')
    fi
    if is_flag_provided "max-budget"; then
        local old_budget new_budget_val
        old_budget=$(echo "$job_json" | jq -r 'if .maxBudgetUsd then "$\(.maxBudgetUsd)" else "none" end')
        if [[ "$MAX_BUDGET" != "-1" ]]; then
            new_budget_val="$MAX_BUDGET"
            changes+=("Budget: $old_budget -> \$$MAX_BUDGET")
        else
            new_budget_val="null"
            changes+=("Budget: $old_budget -> none")
        fi
        job_json=$(echo "$job_json" | jq --argjson v "$new_budget_val" '.maxBudgetUsd = $v')
    fi
    if is_flag_provided "effort"; then
        local old_effort
        old_effort=$(echo "$job_json" | jq -r '.effort // ""')
        changes+=("Effort: '$old_effort' -> '$EFFORT'")
        job_json=$(echo "$job_json" | jq --arg v "${EFFORT:-}" '.effort = $v')
    fi
    if is_flag_provided "work-dir"; then
        changes+=("WorkDir: updated")
        job_json=$(echo "$job_json" | jq --arg v "${WORK_DIR:-~}" '.workingDirectory = $v')
    fi
    if is_flag_provided "allowed-tools"; then
        changes+=("AllowedTools: updated")
        job_json=$(echo "$job_json" | jq --argjson v "$(echo "${ALLOWED_TOOLS:-}" | jq -R 'if . == "" then [] else split(",") end')" '.allowedTools = $v')
    fi
    if is_flag_provided "disallowed-tools"; then
        changes+=("DisallowedTools: updated")
        job_json=$(echo "$job_json" | jq --argjson v "$(echo "${DISALLOWED_TOOLS:-}" | jq -R 'if . == "" then [] else split(",") end')" '.disallowedTools = $v')
    fi
    if is_flag_provided "log-retention"; then
        local old_retention
        old_retention=$(echo "$job_json" | jq -r '.logRetentionDays')
        changes+=("LogRetention: $old_retention -> $LOG_RETENTION days")
        job_json=$(echo "$job_json" | jq --argjson v "$LOG_RETENTION" '.logRetentionDays = $v')
    fi
    if is_flag_provided "append-system-prompt"; then
        changes+=("AppendSystemPrompt: updated")
        local sp_val
        if [[ -n "$APPEND_SYSTEM_PROMPT" ]]; then
            sp_val="\"$APPEND_SYSTEM_PROMPT\""
        else
            sp_val="null"
        fi
        job_json=$(echo "$job_json" | jq --arg v "${APPEND_SYSTEM_PROMPT:-}" 'if $v == "" then .appendSystemPrompt = null else .appendSystemPrompt = $v end')
    fi

    # If schedule changed: reset run status (clears one-time guard) and auto-re-enable
    local was_re_enabled=false
    if is_flag_provided "schedule"; then
        # Reset lastRunStatus/lastRunAt so one-time jobs can run again
        job_json=$(echo "$job_json" | jq '.lastRunStatus = null | .lastRunAt = null | .lastRunDurationSec = null')
        changes+=("Run history: reset (schedule changed)")

        local is_disabled
        is_disabled=$(echo "$job_json" | jq -r '.enabled')
        if [[ "$is_disabled" == "false" ]]; then
            job_json=$(echo "$job_json" | jq '.enabled = true')
            was_re_enabled=true
            changes+=("Enabled: No -> Yes (auto-enabled with new schedule)")
        fi
    fi

    # Save updated JSON
    echo "$job_json" > "$job_file"

    # Re-register launchd if schedule changed or job was re-enabled
    if is_flag_provided "schedule" || [[ "$was_re_enabled" == "true" ]]; then
        unload_job "$NAME"
        local sched
        sched=$(echo "$job_json" | jq -r '.schedule')
        if ! generate_plist "$NAME" "$sched"; then
            echo "Error: Failed to regenerate plist." >&2
            exit 1
        fi
        load_job "$NAME"
        echo "launchd agent updated."

        if [[ "$was_re_enabled" == "true" ]]; then
            enable_job "$NAME"
        fi
    fi

    # Summary
    echo ""
    echo "Updated job '$NAME':"
    for change in "${changes[@]}"; do
        echo "  - $change"
    done
    if [[ "$was_re_enabled" == "true" ]]; then
        echo ""
        echo "  Job was disabled and has been re-enabled with the new schedule."
    fi
    echo ""
    echo "  Status : claude-scheduler.sh status --name $NAME"
    echo "  Run now: claude-scheduler.sh run --name $NAME"
}

cmd_enable() {
    if ! validate_job_name "$NAME"; then exit 1; fi
    local job_file="$JOBS_DIR/$NAME.json"
    if [[ ! -f "$job_file" ]]; then
        echo "Error: Job '$NAME' not found." >&2
        exit 1
    fi

    local updated
    updated=$(jq '.enabled = true' "$job_file")
    echo "$updated" > "$job_file"

    # Regenerate plist and load (in case it was bootout'd)
    local sched
    sched=$(jq -r '.schedule' "$job_file")
    generate_plist "$NAME" "$sched" >/dev/null 2>&1 || true
    enable_job "$NAME"

    echo "Enabled job '$NAME'"
}

cmd_disable() {
    if ! validate_job_name "$NAME"; then exit 1; fi
    local job_file="$JOBS_DIR/$NAME.json"
    if [[ ! -f "$job_file" ]]; then
        echo "Error: Job '$NAME' not found." >&2
        exit 1
    fi

    local updated
    updated=$(jq '.enabled = false' "$job_file")
    echo "$updated" > "$job_file"

    disable_job "$NAME"

    echo "Disabled job '$NAME' (preserved, will not run until re-enabled)"
}

cmd_run() {
    if ! validate_job_name "$NAME"; then exit 1; fi
    local job_file="$JOBS_DIR/$NAME.json"
    if [[ ! -f "$job_file" ]]; then
        echo "Error: Job '$NAME' not found." >&2
        exit 1
    fi

    if [[ -n "$BACKGROUND" ]]; then
        # Run via launchd kickstart
        if kickstart_job "$NAME"; then
            echo "Started job '$NAME' in background via launchd."
            echo "Check logs: claude-scheduler.sh logs --name $NAME"
        else
            echo "Error: Could not start task. Is the job loaded in launchd?" >&2
            echo "Try: claude-scheduler.sh enable --name $NAME" >&2
            exit 1
        fi
    else
        # Run inline (visible output)
        if [[ ! -f "$RUNNER_PATH" ]]; then
            echo "Error: Runner not found at: $RUNNER_PATH" >&2
            exit 1
        fi

        echo "Running job '$NAME' inline..."
        echo "---"
        set +e
        bash "$RUNNER_PATH" "$NAME"
        local run_exit_code=$?
        set -e
        echo "---"

        if [[ $run_exit_code -eq 0 ]]; then
            echo "Job '$NAME' completed successfully."
        else
            echo "Job '$NAME' failed with exit code $run_exit_code."
        fi
    fi
}

cmd_delete() {
    if ! validate_job_name "$NAME"; then exit 1; fi
    local job_file="$JOBS_DIR/$NAME.json"
    if [[ ! -f "$job_file" ]]; then
        echo "Error: Job '$NAME' not found." >&2
        exit 1
    fi

    local job_log_dir="$LOGS_DIR/$NAME"
    local has_logs=false
    if [[ -d "$job_log_dir" ]]; then has_logs=true; fi

    echo "Delete job '$NAME'?"
    echo "  - launchd agent"
    echo "  - Job definition ($job_file)"
    if [[ "$has_logs" == "true" && -z "$KEEP_LOGS" ]]; then
        echo "  - All logs ($job_log_dir)"
    elif [[ "$has_logs" == "true" && -n "$KEEP_LOGS" ]]; then
        echo "  - Logs will be PRESERVED at: $job_log_dir"
    fi

    printf "Type 'yes' to confirm: "
    read -r confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Cancelled."
        exit 0
    fi

    # Remove launchd entry
    unload_job "$NAME"
    local plist_path
    plist_path=$(get_plist_path "$NAME")
    rm -f "$plist_path"
    echo "Removed launchd agent."

    # Remove job JSON
    rm -f "$job_file"
    echo "Removed job definition."

    # Remove logs (unless --keep-logs)
    if [[ -z "$KEEP_LOGS" && "$has_logs" == "true" ]]; then
        rm -rf "$job_log_dir"
        echo "Removed logs."
    elif [[ -n "$KEEP_LOGS" && "$has_logs" == "true" ]]; then
        echo "Logs preserved at: $job_log_dir"
    fi

    # Remove lockfile if present
    rm -f "$SCHEDULER_DIR/.lock-$NAME"

    echo "Deleted job '$NAME'."
}

cmd_logs() {
    if ! validate_job_name "$NAME"; then exit 1; fi
    local job_log_dir="$LOGS_DIR/$NAME"

    if [[ ! -d "$job_log_dir" ]]; then
        echo "No logs found for job '$NAME'."
        exit 0
    fi

    # Find log files sorted by name descending (newest first, since names are timestamps)
    local latest
    latest=$(find "$job_log_dir" -name "*.log" -not -name "launchd-*" -maxdepth 1 2>/dev/null | sort -r | head -1)

    if [[ -z "$latest" ]]; then
        echo "No log files found for job '$NAME'."
        exit 0
    fi

    local total_logs
    total_logs=$(find "$job_log_dir" -name "*.log" -not -name "launchd-*" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
    local oldest newest
    oldest=$(find "$job_log_dir" -name "*.log" -not -name "launchd-*" -maxdepth 1 2>/dev/null | sort | head -1 | xargs basename 2>/dev/null || echo "-")
    newest=$(basename "$latest" 2>/dev/null || echo "-")

    echo "=== Latest log: $(basename "$latest") ==="
    echo "Log file: $latest"
    echo "Total log files: $total_logs (oldest: $oldest, newest: $newest)"
    echo "---"

    tail -n "$TAIL_LINES" "$latest"
}

cmd_purge_logs() {
    local target_dirs=()
    if [[ -n "$NAME" ]]; then
        target_dirs+=("$LOGS_DIR/$NAME")
    else
        while IFS= read -r dir; do
            [[ -n "$dir" ]] && target_dirs+=("$dir")
        done < <(find "$LOGS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi

    if [[ ${#target_dirs[@]} -eq 0 ]]; then
        echo "No log directories found."
        exit 0
    fi

    local total_purged=0
    local total_jobs=0

    for dir in "${target_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then continue; fi
        local count=0
        while IFS= read -r old_log; do
            [[ -z "$old_log" ]] && continue
            rm -f "$old_log"
            count=$((count + 1))
        done < <(find "$dir" -name "*.log" -not -name "launchd-*" -mtime +"$DAYS" 2>/dev/null)
        if [[ $count -gt 0 ]]; then
            total_purged=$((total_purged + count))
            total_jobs=$((total_jobs + 1))
        fi
    done

    echo "Purged $total_purged log files across $total_jobs jobs (older than $DAYS days)"
}

cmd_status() {
    if ! validate_job_name "$NAME"; then exit 1; fi
    local job_file="$JOBS_DIR/$NAME.json"
    if [[ ! -f "$job_file" ]]; then
        echo "Error: Job '$NAME' not found." >&2
        exit 1
    fi

    # Read job fields
    local job_name job_desc job_schedule job_enabled job_model job_budget job_effort job_workdir job_retention
    local job_last_run job_last_status job_last_duration
    job_name=$(jq -r '.name // "?"' "$job_file")
    job_desc=$(jq -r '.description // "-"' "$job_file")
    job_schedule=$(jq -r '.schedule // "?"' "$job_file")
    job_enabled=$(jq -r 'if .enabled then "Yes" else "No" end' "$job_file")
    job_model=$(jq -r '.model // "default"' "$job_file")
    job_budget=$(jq -r 'if .maxBudgetUsd then "$\(.maxBudgetUsd)" else "-" end' "$job_file")
    job_effort=$(jq -r '.effort // "-"' "$job_file")
    job_workdir=$(jq -r '.workingDirectory // "~"' "$job_file")
    job_retention=$(jq -r '.logRetentionDays // 30' "$job_file")
    job_last_run=$(jq -r '.lastRunAt // ""' "$job_file")
    job_last_status=$(jq -r '.lastRunStatus // ""' "$job_file")
    job_last_duration=$(jq -r '.lastRunDurationSec // ""' "$job_file")

    # launchd status
    local launchd_state="NOT LOADED"
    if check_launchd_loaded "$job_name"; then
        launchd_state="LOADED"
    fi

    # Log stats
    local log_count=0 log_size=0 oldest_log="-" newest_log="-"
    local job_log_dir="$LOGS_DIR/$job_name"
    if [[ -d "$job_log_dir" ]]; then
        log_count=$(find "$job_log_dir" -name "*.log" -not -name "launchd-*" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
        if [[ $log_count -gt 0 ]]; then
            log_size=$(du -sk "$job_log_dir" 2>/dev/null | awk '{print $1}')
            oldest_log=$(find "$job_log_dir" -name "*.log" -not -name "launchd-*" -maxdepth 1 2>/dev/null | sort | head -1 | xargs basename 2>/dev/null | sed 's/\.log$//')
            newest_log=$(find "$job_log_dir" -name "*.log" -not -name "launchd-*" -maxdepth 1 2>/dev/null | sort -r | head -1 | xargs basename 2>/dev/null | sed 's/\.log$//')
        fi
    fi

    # Format last run
    local last_run_display="never"
    if [[ -n "$job_last_run" && "$job_last_run" != "null" ]]; then
        last_run_display="$job_last_run ($job_last_status, ${job_last_duration}s)"
    fi

    echo ""
    echo "  Job          : $job_name"
    echo "  Description  : $job_desc"
    echo "  Schedule     : $job_schedule"
    echo "  Enabled      : $job_enabled"
    echo "  Model        : $job_model"
    if [[ "$job_budget" != "-" ]]; then
        echo "  Budget       : $job_budget"
    fi
    echo "  Effort       : $job_effort"
    echo "  Working Dir  : $job_workdir"
    echo "  Log Retention: $job_retention days"
    echo ""
    echo "  Agent State  : $launchd_state"
    echo "  Last Run     : $last_run_display"
    echo ""
    echo "  Logs         : $log_count files (${log_size} KB)"
    echo "  Oldest Log   : $oldest_log"
    echo "  Newest Log   : $newest_log"
    echo ""
}

cmd_setup_notify() {
    local notify_file="$SCHEDULER_DIR/notify.json"

    # Disable notifications
    if [[ -n "$DISABLE_NOTIFY" ]]; then
        if [[ -f "$notify_file" ]]; then
            local updated
            updated=$(jq '.enabled = false' "$notify_file")
            echo "$updated" > "$notify_file"
            echo "Notifications disabled."
        else
            echo "No notification config found. Nothing to disable."
        fi
        exit 0
    fi

    # Show current config if no params provided
    if [[ -z "$NOTIFY_COMMAND" ]]; then
        if [[ -f "$notify_file" ]]; then
            echo "=== Notification Config ==="
            echo "  Enabled  : $(jq -r '.enabled' "$notify_file")"
            echo "  Command  : $(jq -r '.command' "$notify_file")"
            echo "  Args     : $(jq -r '.args | join(" ")' "$notify_file")"
            echo "  Notify On: $(jq -r '.notifyOn | join(", ")' "$notify_file")"
            echo ""
            echo "Test: claude-scheduler.sh test-notify"
            echo "Disable: claude-scheduler.sh setup-notify --disable"
        else
            echo "No notification config found."
            echo ""
            echo "Set up with:"
            echo '  claude-scheduler.sh setup-notify --notify-command <cmd> --notify-args <args>'
            echo ""
            echo "The notification command receives {{message}} replaced with failure details."
        fi
        exit 0
    fi

    # Parse notify args (comma-separated)
    local args_array="[]"
    if [[ -n "$NOTIFY_ARGS" ]]; then
        args_array=$(echo "$NOTIFY_ARGS" | jq -R 'split(",")')
    fi

    # Validate args contain {{message}} placeholder
    local has_placeholder=false
    if echo "$NOTIFY_ARGS" | grep -q '{{message}}'; then
        has_placeholder=true
    fi
    if [[ "$has_placeholder" == "false" ]]; then
        echo "WARNING: Your --notify-args do not contain '{{message}}'."
        echo "The notification will fire but won't include failure details."
        echo ""
    fi

    # Build notify-on values
    local notify_on_array
    if [[ -n "$NOTIFY_ON" ]]; then
        notify_on_array=$(echo "$NOTIFY_ON" | jq -R 'split(",")')
    else
        notify_on_array='["job-failure","all-failures"]'
    fi

    # Build config
    jq -n \
        --argjson enabled true \
        --arg method "command" \
        --arg command "$NOTIFY_COMMAND" \
        --argjson args "$args_array" \
        --argjson notifyOn "$notify_on_array" \
        '{enabled: $enabled, method: $method, command: $command, args: $args, notifyOn: $notifyOn}' \
        > "$notify_file"

    echo "Notification config saved to: $notify_file"
    echo "  Command  : $NOTIFY_COMMAND"
    echo "  Args     : $NOTIFY_ARGS"
    echo "  Notify On: $(echo "$notify_on_array" | jq -r 'join(", ")')"
    echo ""
    echo "Test it: claude-scheduler.sh test-notify"
}

cmd_test_notify() {
    local notify_file="$SCHEDULER_DIR/notify.json"
    if [[ ! -f "$notify_file" ]]; then
        echo "No notification config found. Run setup-notify first."
        exit 1
    fi

    local enabled
    enabled=$(jq -r '.enabled // false' "$notify_file")
    if [[ "$enabled" != "true" ]]; then
        echo "Notifications are disabled. Enable with: claude-scheduler.sh setup-notify --notify-command ..."
        exit 1
    fi

    echo "Sending test notification..."
    local test_message="[Claude Scheduler] Test notification - if you see this, notifications are working!"

    local cmd
    cmd=$(jq -r '.command' "$notify_file")
    local cmd_args=()
    while IFS= read -r arg; do
        cmd_args+=("${arg//\{\{message\}\}/$test_message}")
    done < <(jq -r '.args[]' "$notify_file")

    if "$cmd" "${cmd_args[@]}" >/dev/null 2>&1; then
        echo "Test notification sent via $cmd"
        echo "Check your device for the message."
    else
        echo "Failed to send test notification." >&2
        echo "Check your --notify-command path and --notify-args." >&2
        exit 1
    fi
}

cmd_usage() {
    echo "Claude Scheduler - Manage scheduled Claude Code jobs (macOS)"
    echo ""
    echo "Usage: claude-scheduler.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  create       Create a new scheduled job"
    echo "  list         List all jobs with status"
    echo "  update       Update an existing job (schedule, prompt, model, etc.)"
    echo "  enable       Enable a disabled job"
    echo "  disable      Temporarily disable a job (preserves it)"
    echo "  run          Run a job immediately"
    echo "  delete       Delete a job permanently (use --keep-logs to preserve logs)"
    echo "  logs         View latest log for a job"
    echo "  purge-logs   Purge old log files"
    echo "  status       Show detailed job status"
    echo "  setup-notify Configure failure notifications"
    echo "  test-notify  Test notification delivery"
    echo ""
    echo "Examples:"
    echo '  claude-scheduler.sh create --name "daily-summary" --prompt "Summarize HN" --schedule "daily 09:00"'
    echo '  claude-scheduler.sh update --name "daily-summary" --schedule "weekly Monday 09:00"'
    echo '  claude-scheduler.sh list'
    echo '  claude-scheduler.sh run --name "daily-summary"'
    echo '  claude-scheduler.sh disable --name "daily-summary"'
    echo ""
    echo "Schedule formats:"
    echo "  daily HH:MM, weekly DAY HH:MM, hourly, every Nm, every Nh,"
    echo "  once YYYY-MM-DD HH:MM, startup, logon"
}

# ============================================================
# COMMAND DISPATCHER
# ============================================================

case "$COMMAND" in
    create)       cmd_create ;;
    list)         cmd_list ;;
    update)       cmd_update ;;
    enable)       cmd_enable ;;
    disable)      cmd_disable ;;
    run)          cmd_run ;;
    delete)       cmd_delete ;;
    logs)         cmd_logs ;;
    purge-logs)   cmd_purge_logs ;;
    status)       cmd_status ;;
    setup-notify) cmd_setup_notify ;;
    test-notify)  cmd_test_notify ;;
    *)            cmd_usage ;;
esac
