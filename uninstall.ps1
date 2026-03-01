#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Scheduler Uninstaller - Clean removal of scheduled Claude Code jobs infrastructure.
.DESCRIPTION
    Removes all Task Scheduler entries, scheduler scripts, and optionally logs.
    Preserves job JSONs as backup by default.
.PARAMETER KeepLogs
    Preserve log files instead of deleting them.
.PARAMETER KeepJobs
    Preserve job definition JSONs as backup.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File uninstall.ps1
#>
param(
    [switch]$KeepLogs,
    [switch]$KeepJobs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '  =================================='
Write-Host '  Claude Scheduler - Uninstaller'
Write-Host '  =================================='
Write-Host ''

$ClaudeDir = Join-Path $env:USERPROFILE '.claude'
$SchedulerDir = Join-Path $ClaudeDir 'scheduler'
$JobsDir = Join-Path $SchedulerDir 'jobs'
$LogsDir = Join-Path $SchedulerDir 'logs'
$SkillDir = Join-Path $ClaudeDir 'skills\claude-scheduler'
$TaskPath = '\ClaudeScheduler\'

# Confirm
Write-Host 'This will remove:'
Write-Host "  - All Task Scheduler entries under $TaskPath"
Write-Host "  - Scheduler scripts from $SchedulerDir"
Write-Host "  - Skill from $SkillDir"
if (-not $KeepLogs) { Write-Host "  - All log files in $LogsDir" }
if (-not $KeepJobs) { Write-Host "  - All job definitions in $JobsDir" }
Write-Host ''
$confirm = Read-Host "Type 'yes' to confirm uninstall"
if ($confirm -ne 'yes') {
    Write-Host 'Cancelled.'
    exit 0
}

Write-Host ''

# Step 1: Remove Task Scheduler entries
Write-Host '[1/4] Removing Task Scheduler entries...'
try {
    $tasks = Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($tasks) {
        foreach ($task in $tasks) {
            Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $task.TaskName -Confirm:$false
            Write-Host "  Removed: $($task.TaskName)"
        }
    } else {
        Write-Host '  No tasks found.'
    }

    # Remove the folder
    try {
        $scheduleService = New-Object -ComObject 'Schedule.Service'
        $scheduleService.Connect()
        $rootFolder = $scheduleService.GetFolder('\')
        try {
            $rootFolder.DeleteFolder('ClaudeScheduler', 0)
            Write-Host '  Removed folder \ClaudeScheduler\'
        } catch {
            Write-Host '  Folder already removed or not empty.'
        }
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($scheduleService) | Out-Null
    } catch {
        Write-Host "  Warning: Could not remove folder: $_"
    }
} catch {
    Write-Host "  Warning: $_ "
}
Write-Host ''

# Step 2: Remove skill
Write-Host '[2/4] Removing skill...'
if (Test-Path $SkillDir) {
    Remove-Item -Path $SkillDir -Recurse -Force
    Write-Host "  Removed: $SkillDir"
} else {
    Write-Host '  Skill not found (already removed).'
}
Write-Host ''

# Step 3: Handle logs
Write-Host '[3/4] Handling logs...'
if ($KeepLogs) {
    Write-Host "  Preserved logs at: $LogsDir"
} else {
    if (Test-Path $LogsDir) {
        Remove-Item -Path $LogsDir -Recurse -Force
        Write-Host "  Removed: $LogsDir"
    } else {
        Write-Host '  No logs found.'
    }
}
Write-Host ''

# Step 4: Remove scheduler directory
Write-Host '[4/4] Removing scheduler files...'
if ($KeepJobs -and (Test-Path $JobsDir)) {
    # Keep jobs, remove everything else
    $backupDir = Join-Path $env:USERPROFILE '.claude\scheduler-jobs-backup'
    Copy-Item -Path $JobsDir -Destination $backupDir -Recurse -Force
    Write-Host "  Job definitions backed up to: $backupDir"
}

if (Test-Path $SchedulerDir) {
    # Remove scripts
    Get-ChildItem -Path $SchedulerDir -File | Remove-Item -Force
    Write-Host '  Removed scripts.'

    # Remove jobs dir if not keeping
    if (-not $KeepJobs -and (Test-Path $JobsDir)) {
        Remove-Item -Path $JobsDir -Recurse -Force
        Write-Host '  Removed job definitions.'
    }

    # Remove logs dir if not already removed and not keeping
    if (-not $KeepLogs -and (Test-Path $LogsDir)) {
        Remove-Item -Path $LogsDir -Recurse -Force
    }

    # Remove scheduler dir if empty
    $remaining = Get-ChildItem -Path $SchedulerDir -Recurse -ErrorAction SilentlyContinue
    if (-not $remaining) {
        Remove-Item -Path $SchedulerDir -Force
        Write-Host "  Removed: $SchedulerDir"
    } else {
        Write-Host "  Directory not empty, preserved: $SchedulerDir"
    }
} else {
    Write-Host '  Scheduler directory not found (already removed).'
}

Write-Host ''
Write-Host '  =================================='
Write-Host '  Uninstall complete.'
Write-Host '  =================================='
Write-Host ''
if ($KeepJobs) {
    Write-Host "  Job backups: $(Join-Path $env:USERPROFILE '.claude\scheduler-jobs-backup')"
}
Write-Host '  If you added a PowerShell alias, remove it from your $PROFILE.'
Write-Host ''
