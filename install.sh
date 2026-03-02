#!/bin/bash
# Claude Scheduler Installer (macOS) - One-command setup for scheduled Claude Code jobs.
#
# Copies scheduler scripts to ~/.claude/scheduler/ and the skill to ~/.claude/skills/.
# Idempotent - safe to re-run. Preserves existing jobs and logs.
#
# Usage: bash install.sh [--force]

set -euo pipefail

FORCE=false
if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
    FORCE=true
fi

# --- Banner ---
echo ''
echo '  =================================='
echo '  Claude Scheduler - macOS Installer'
echo '  =================================='
echo ''

# --- Paths ---
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SCHEDULER_DIR="$CLAUDE_DIR/scheduler"
JOBS_DIR="$SCHEDULER_DIR/jobs"
LOGS_DIR="$SCHEDULER_DIR/logs"
SKILL_DIR="$CLAUDE_DIR/skills/claude-scheduler"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

# --- Step 1: Prerequisites ---
echo '[1/6] Checking prerequisites...'

# Bash version (informational)
echo "  Bash: $BASH_VERSION"

# jq (required)
if command -v jq &>/dev/null; then
    echo "  jq: $(jq --version 2>&1)"
    echo '  OK'
else
    echo '  ERROR: jq is required but not found.' >&2
    echo '  Install with: brew install jq' >&2
    exit 1
fi

# Claude CLI
if command -v claude &>/dev/null; then
    echo "  Claude CLI: $(claude --version 2>&1)"
    echo '  OK'
else
    echo '  WARNING: Claude CLI not found on PATH.'
    echo '  Install with: npm install -g @anthropic-ai/claude-code'
    echo '  Or install the Claude desktop app.'
    echo '  The scheduler will not work until Claude CLI is available.'
    echo ''
fi

# Check skipDangerousModePermissionPrompt
settings_file="$CLAUDE_DIR/settings.json"
if [[ -f "$settings_file" ]]; then
    skip_val=$(jq -r '.skipDangerousModePermissionPrompt // false' "$settings_file" 2>/dev/null)
    if [[ "$skip_val" == "true" ]]; then
        echo '  skipDangerousModePermissionPrompt: true'
        echo '  OK'
    else
        echo '  WARNING: skipDangerousModePermissionPrompt is not set to true.'
        echo '  Scheduled tasks may hang on a permission prompt.'
        echo "  Fix: Run 'claude --dangerously-skip-permissions' once interactively to accept."
    fi
else
    echo '  WARNING: ~/.claude/settings.json not found.'
    echo '  Make sure Claude CLI has been run at least once.'
fi

echo ''

# --- Step 2: Create directories ---
echo '[2/6] Creating directories...'
for dir in "$SCHEDULER_DIR" "$JOBS_DIR" "$LOGS_DIR" "$SKILL_DIR" "$LAUNCH_AGENTS_DIR"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        echo "  Created: $dir"
    else
        echo "  Exists:  $dir"
    fi
done
echo ''

# --- Step 3: Copy scripts ---
echo '[3/6] Copying scripts...'
FILES_TO_COPY=("claude-scheduler.sh" "runner.sh")
for file in "${FILES_TO_COPY[@]}"; do
    src="$SOURCE_DIR/$file"
    dest="$SCHEDULER_DIR/$file"

    if [[ ! -f "$src" ]]; then
        echo "  MISSING: $src"
        continue
    fi

    if [[ -f "$dest" ]] && [[ "$FORCE" != "true" ]]; then
        src_hash=$(shasum -a 256 "$src" | awk '{print $1}')
        dest_hash=$(shasum -a 256 "$dest" | awk '{print $1}')
        if [[ "$src_hash" == "$dest_hash" ]]; then
            echo "  Up to date: $file"
            continue
        fi
        echo "  Updated: $file"
    else
        echo "  Copied: $file"
    fi

    cp "$src" "$dest"
done
echo ''

# --- Step 4: Install skill ---
echo '[4/6] Installing skill...'
skill_src="$SOURCE_DIR/skill/SKILL.md"
skill_dest="$SKILL_DIR/SKILL.md"

if [[ -f "$skill_src" ]]; then
    if [[ -f "$skill_dest" ]] && [[ "$FORCE" != "true" ]]; then
        src_hash=$(shasum -a 256 "$skill_src" | awk '{print $1}')
        dest_hash=$(shasum -a 256 "$skill_dest" | awk '{print $1}')
        if [[ "$src_hash" == "$dest_hash" ]]; then
            echo "  Up to date: SKILL.md"
        else
            cp "$skill_src" "$skill_dest"
            echo "  Updated: SKILL.md"
        fi
    else
        cp "$skill_src" "$skill_dest"
        echo "  Copied: SKILL.md"
    fi
else
    echo "  MISSING: $skill_src"
fi
echo ''

# --- Step 5: Set file permissions ---
echo '[5/6] Setting file permissions...'
chmod +x "$SCHEDULER_DIR/claude-scheduler.sh" 2>/dev/null && echo "  +x: claude-scheduler.sh" || true
chmod +x "$SCHEDULER_DIR/runner.sh" 2>/dev/null && echo "  +x: runner.sh" || true
echo ''

# --- Step 6: Verify LaunchAgents directory ---
echo '[6/6] Verifying LaunchAgents directory...'
if [[ -d "$LAUNCH_AGENTS_DIR" ]]; then
    echo "  ~/Library/LaunchAgents/ exists."
else
    mkdir -p "$LAUNCH_AGENTS_DIR"
    echo "  Created: ~/Library/LaunchAgents/"
fi
echo ''

# --- Success ---
echo '  =================================='
echo '  Installation complete!'
echo '  =================================='
echo ''
echo "  Scripts:  $SCHEDULER_DIR"
echo "  Skill:    $SKILL_DIR"
echo "  Jobs:     $JOBS_DIR"
echo "  Logs:     $LOGS_DIR"
echo ''
echo '  Quick start:'
echo "    # From terminal:"
echo "    bash $SCHEDULER_DIR/claude-scheduler.sh list"
echo ''
echo "    # Create a job:"
echo "    bash $SCHEDULER_DIR/claude-scheduler.sh create --name \"test\" --prompt \"Say hello\" --schedule \"daily 09:00\""
echo ''
echo '    # Or use the skill in Claude Code:'
echo '    /claude-scheduler schedule "Summarize HN" to run daily at 9am'
echo ''
echo '  Optional: Add a shell alias for convenience.'
echo '  Add this to your ~/.zshrc or ~/.bashrc:'
echo "    alias cs='bash $SCHEDULER_DIR/claude-scheduler.sh'"
echo ''
