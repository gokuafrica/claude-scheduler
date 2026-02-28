#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Scheduler Installer - One-command setup for scheduled Claude Code jobs.
.DESCRIPTION
    Copies scheduler scripts to ~/.claude/scheduler/ and the skill to ~/.claude/skills/.
    Idempotent - safe to re-run. Preserves existing jobs and logs.
.PARAMETER Force
    Overwrite existing files without prompting.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
#>
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Banner ---
Write-Host ''
Write-Host '  =================================='
Write-Host '  Claude Scheduler - Installer'
Write-Host '  =================================='
Write-Host ''

# --- Paths ---
$SourceDir = $PSScriptRoot
$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$SchedulerDir = Join-Path $ClaudeDir 'scheduler'
$JobsDir = Join-Path $SchedulerDir 'jobs'
$LogsDir = Join-Path $SchedulerDir 'logs'
$SkillDir = Join-Path $ClaudeDir 'skills\claude-scheduler'

# --- Source files ---
$sourceFiles = @{
    'claude-scheduler.ps1' = Join-Path $SourceDir 'claude-scheduler.ps1'
    'runner.ps1'           = Join-Path $SourceDir 'runner.ps1'
}
$skillSource = Join-Path $SourceDir 'skill\SKILL.md'

# --- Step 1: Prerequisites ---
Write-Host '[1/6] Checking prerequisites...'

# PowerShell version
$psVersion = $PSVersionTable.PSVersion
Write-Host "  PowerShell: $psVersion"
if ($psVersion.Major -lt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -lt 1)) {
    Write-Error 'PowerShell 5.1 or later is required.'
    exit 1
}
Write-Host '  OK' -ForegroundColor Green

# Claude CLI
Write-Host '  Checking Claude CLI...'
try {
    $claudeVersion = & claude --version 2>&1
    Write-Host "  Claude CLI: $claudeVersion"
    Write-Host '  OK' -ForegroundColor Green
} catch {
    Write-Host '  WARNING: Claude CLI not found on PATH.' -ForegroundColor Yellow
    Write-Host '  Install it with: npm install -g @anthropic-ai/claude-code'
    Write-Host '  The scheduler will not work until Claude CLI is available.'
    Write-Host ''
}

# Check skipDangerousModePermissionPrompt
$settingsFile = Join-Path $ClaudeDir 'settings.json'
if (Test-Path $settingsFile) {
    try {
        $settings = Get-Content -Path $settingsFile -Raw | ConvertFrom-Json
        if ($settings.skipDangerousModePermissionPrompt -eq $true) {
            Write-Host '  skipDangerousModePermissionPrompt: true'
            Write-Host '  OK' -ForegroundColor Green
        } else {
            Write-Host '  WARNING: skipDangerousModePermissionPrompt is not set to true.' -ForegroundColor Yellow
            Write-Host '  Scheduled tasks may hang on a permission prompt.'
            Write-Host '  Fix: Run "claude --dangerously-skip-permissions" once interactively to accept.'
        }
    } catch {
        Write-Host '  Could not read settings.json. Continuing...' -ForegroundColor Yellow
    }
} else {
    Write-Host '  WARNING: ~/.claude/settings.json not found.' -ForegroundColor Yellow
    Write-Host '  Make sure Claude CLI has been run at least once.'
}

Write-Host ''

# --- Step 2: Create directories ---
Write-Host '[2/6] Creating directories...'
foreach ($dir in @($SchedulerDir, $JobsDir, $LogsDir, $SkillDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "  Created: $dir"
    } else {
        Write-Host "  Exists:  $dir"
    }
}
Write-Host ''

# --- Step 3: Copy scripts ---
Write-Host '[3/6] Copying scripts...'
foreach ($entry in $sourceFiles.GetEnumerator()) {
    $destFile = Join-Path $SchedulerDir $entry.Key
    $srcFile = $entry.Value

    if (-not (Test-Path $srcFile)) {
        Write-Host "  MISSING: $srcFile" -ForegroundColor Red
        continue
    }

    if ((Test-Path $destFile) -and -not $Force) {
        $srcHash = (Get-FileHash $srcFile).Hash
        $destHash = (Get-FileHash $destFile).Hash
        if ($srcHash -eq $destHash) {
            Write-Host "  Up to date: $($entry.Key)"
            continue
        }
        Write-Host "  Updated: $($entry.Key)"
    } else {
        Write-Host "  Copied: $($entry.Key)"
    }

    Copy-Item -Path $srcFile -Destination $destFile -Force
}
Write-Host ''

# --- Step 4: Copy skill ---
Write-Host '[4/6] Installing skill...'
$skillDest = Join-Path $SkillDir 'SKILL.md'
if (Test-Path $skillSource) {
    if ((Test-Path $skillDest) -and -not $Force) {
        $srcHash = (Get-FileHash $skillSource).Hash
        $destHash = (Get-FileHash $skillDest).Hash
        if ($srcHash -eq $destHash) {
            Write-Host "  Up to date: SKILL.md"
        } else {
            Copy-Item -Path $skillSource -Destination $skillDest -Force
            Write-Host "  Updated: SKILL.md"
        }
    } else {
        Copy-Item -Path $skillSource -Destination $skillDest -Force
        Write-Host "  Copied: SKILL.md"
    }
} else {
    Write-Host "  MISSING: $skillSource" -ForegroundColor Red
}
Write-Host ''

# --- Step 5: Unblock files ---
Write-Host '[5/6] Unblocking scripts (removing Zone.Identifier)...'
Get-ChildItem -Path $SchedulerDir -Filter '*.ps1' | ForEach-Object {
    Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
    Write-Host "  Unblocked: $($_.Name)"
}
Write-Host ''

# --- Step 6: Create Task Scheduler folder ---
Write-Host '[6/6] Ensuring Task Scheduler folder exists...'
try {
    $scheduleService = New-Object -ComObject 'Schedule.Service'
    $scheduleService.Connect()
    $rootFolder = $scheduleService.GetFolder('\')
    try {
        $null = $rootFolder.GetFolder('ClaudeScheduler')
        Write-Host '  Folder \ClaudeScheduler\ already exists.'
    } catch {
        $null = $rootFolder.CreateFolder('ClaudeScheduler')
        Write-Host '  Created folder \ClaudeScheduler\'
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($scheduleService) | Out-Null
} catch {
    Write-Host "  WARNING: Could not create Task Scheduler folder: $_" -ForegroundColor Yellow
    Write-Host '  It will be created automatically when you create your first job.'
}
Write-Host ''

# --- Success ---
Write-Host '  =================================='
Write-Host '  Installation complete!'
Write-Host '  =================================='
Write-Host ''
Write-Host "  Scripts:  $SchedulerDir"
Write-Host "  Skill:    $SkillDir"
Write-Host "  Jobs:     $JobsDir"
Write-Host "  Logs:     $LogsDir"
Write-Host ''
Write-Host '  Quick start:'
Write-Host "    # From PowerShell:"
Write-Host "    & `"$SchedulerDir\claude-scheduler.ps1`" list"
Write-Host ''
Write-Host "    # Create a job:"
Write-Host "    & `"$SchedulerDir\claude-scheduler.ps1`" create -Name `"test`" -Prompt `"Say hello`" -Schedule `"daily 09:00`""
Write-Host ''
Write-Host "    # Or use the skill in Claude Code:"
Write-Host '    /claude-scheduler schedule "Summarize HN" to run daily at 9am'
Write-Host ''
Write-Host '  Optional: Add a PowerShell alias for convenience.'
Write-Host '  Add this to your $PROFILE:'
Write-Host "    Set-Alias -Name cs -Value `"$SchedulerDir\claude-scheduler.ps1`""
Write-Host ''
