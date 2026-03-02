#!/bin/bash
# Claude Scheduler Uninstaller - Clean removal of scheduled Claude Code jobs.
#
# Removes all launchd agents, scheduler scripts, and optionally logs.
# Preserves job JSONs as backup by default with --keep-jobs.
#
# Usage: bash uninstall.sh [--keep-logs] [--keep-jobs]

set -euo pipefail

KEEP_LOGS=false
KEEP_JOBS=false
for arg in "$@"; do
    case "$arg" in
        --keep-logs) KEEP_LOGS=true ;;
        --keep-jobs) KEEP_JOBS=true ;;
    esac
done

echo ''
echo '  ================================'
echo '  Claude Scheduler - Uninstaller'
echo '  ================================'
echo ''

CLAUDE_DIR="$HOME/.claude"
SCHEDULER_DIR="$CLAUDE_DIR/scheduler"
JOBS_DIR="$SCHEDULER_DIR/jobs"
LOGS_DIR="$SCHEDULER_DIR/logs"
SKILL_DIR="$CLAUDE_DIR/skills/claude-scheduler"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="com.claude-scheduler."

# Show what will be removed
echo 'This will remove:'
echo "  - All launchd agents matching ${LABEL_PREFIX}*"
echo "  - Scheduler scripts from $SCHEDULER_DIR"
echo "  - Skill from $SKILL_DIR"
if [[ "$KEEP_LOGS" != "true" ]]; then
    echo "  - All log files in $LOGS_DIR"
fi
if [[ "$KEEP_JOBS" != "true" ]]; then
    echo "  - All job definitions in $JOBS_DIR"
fi
echo ''

printf "Type 'yes' to confirm uninstall: "
read -r confirm
if [[ "$confirm" != "yes" ]]; then
    echo 'Cancelled.'
    exit 0
fi

echo ''

# Step 1: Remove launchd entries
echo '[1/4] Removing launchd agents...'
uid=$(id -u)
found_any=false

for plist in "$LAUNCH_AGENTS_DIR/${LABEL_PREFIX}"*.plist; do
    if [[ -f "$plist" ]]; then
        found_any=true
        label=$(basename "$plist" .plist)
        # Try to bootout first
        launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
        rm -f "$plist"
        echo "  Removed: $label"
    fi
done

if [[ "$found_any" == "false" ]]; then
    echo '  No launchd agents found.'
fi
echo ''

# Step 2: Remove skill
echo '[2/4] Removing skill...'
if [[ -d "$SKILL_DIR" ]]; then
    rm -rf "$SKILL_DIR"
    echo "  Removed: $SKILL_DIR"
else
    echo '  Skill not found (already removed).'
fi
echo ''

# Step 3: Handle logs
echo '[3/4] Handling logs...'
if [[ "$KEEP_LOGS" == "true" ]]; then
    echo "  Preserved logs at: $LOGS_DIR"
else
    if [[ -d "$LOGS_DIR" ]]; then
        rm -rf "$LOGS_DIR"
        echo "  Removed: $LOGS_DIR"
    else
        echo '  No logs found.'
    fi
fi
echo ''

# Step 4: Remove scheduler directory
echo '[4/4] Removing scheduler files...'

# Backup jobs if requested
if [[ "$KEEP_JOBS" == "true" ]] && [[ -d "$JOBS_DIR" ]]; then
    backup_dir="$CLAUDE_DIR/scheduler-jobs-backup"
    cp -r "$JOBS_DIR" "$backup_dir"
    echo "  Job definitions backed up to: $backup_dir"
fi

if [[ -d "$SCHEDULER_DIR" ]]; then
    # Remove scripts and lockfiles
    find "$SCHEDULER_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
    echo '  Removed scripts.'

    # Remove jobs dir if not keeping
    if [[ "$KEEP_JOBS" != "true" ]] && [[ -d "$JOBS_DIR" ]]; then
        rm -rf "$JOBS_DIR"
        echo '  Removed job definitions.'
    fi

    # Remove logs dir if not already removed and not keeping
    if [[ "$KEEP_LOGS" != "true" ]] && [[ -d "$LOGS_DIR" ]]; then
        rm -rf "$LOGS_DIR"
    fi

    # Remove scheduler dir if empty
    if [[ -z "$(ls -A "$SCHEDULER_DIR" 2>/dev/null)" ]]; then
        rmdir "$SCHEDULER_DIR"
        echo "  Removed: $SCHEDULER_DIR"
    else
        echo "  Directory not empty, preserved: $SCHEDULER_DIR"
    fi
else
    echo '  Scheduler directory not found (already removed).'
fi

echo ''
echo '  =================================='
echo '  Uninstall complete.'
echo '  =================================='
echo ''
if [[ "$KEEP_JOBS" == "true" ]]; then
    echo "  Job backups: $CLAUDE_DIR/scheduler-jobs-backup"
fi
echo '  If you added a shell alias, remove it from your ~/.zshrc or ~/.bashrc.'
echo ''
