#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Scheduler - Manage scheduled Claude Code jobs on Windows.
.DESCRIPTION
    Create, list, enable, disable, run, delete, and monitor scheduled Claude Code jobs
    that run via Windows Task Scheduler.
.EXAMPLE
    claude-scheduler.ps1 create -Name "daily-summary" -Prompt "Summarize HN" -Schedule "daily 09:00"
    claude-scheduler.ps1 list
    claude-scheduler.ps1 run -Name "daily-summary"
    claude-scheduler.ps1 disable -Name "daily-summary"
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('create', 'list', 'enable', 'disable', 'run', 'delete', 'logs', 'purge-logs', 'status')]
    [string]$Command,

    [string]$Name,
    [string]$Prompt,
    [string]$Schedule,
    [string]$Description,
    [string]$Model,
    [double]$MaxBudget = 0,
    [string[]]$AllowedTools,
    [string[]]$DisallowedTools,
    [string]$WorkDir,
    [string]$McpConfig,
    [string]$Effort,
    [int]$LogRetention = 30,
    [string]$AppendSystemPrompt,
    [switch]$NoSessionPersistence,
    [switch]$Background,

    # Logs parameters
    [int]$Tail = 50,

    # Purge-logs parameters
    [int]$Days = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Paths ---
$SchedulerDir = Join-Path $env:USERPROFILE '.claude\scheduler'
$JobsDir = Join-Path $SchedulerDir 'jobs'
$LogsDir = Join-Path $SchedulerDir 'logs'
$RunnerPath = Join-Path $SchedulerDir 'runner.ps1'
$TaskPath = '\ClaudeScheduler\'

# --- Ensure directories exist ---
foreach ($dir in @($SchedulerDir, $JobsDir, $LogsDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# --- Helper: Validate job name ---
function Test-JobName {
    param([string]$JobName)
    if (-not $JobName) {
        Write-Error "Job name is required. Use -Name to specify."
        return $false
    }
    if ($JobName -notmatch '^[a-zA-Z0-9_-]+$') {
        Write-Error "Job name must contain only letters, numbers, hyphens, and underscores. Got: '$JobName'"
        return $false
    }
    return $true
}

# --- Helper: Parse schedule string to Task Scheduler trigger ---
function ConvertTo-ScheduledTaskTrigger {
    param([string]$ScheduleStr)

    switch -Regex ($ScheduleStr.Trim()) {
        '^daily\s+(\d{1,2}):(\d{2})$' {
            $hour = [int]$Matches[1]
            $minute = [int]$Matches[2]
            $time = Get-Date -Hour $hour -Minute $minute -Second 0
            return New-ScheduledTaskTrigger -Daily -At $time
        }
        '^weekly\s+(\w+)\s+(\d{1,2}):(\d{2})$' {
            $dayName = $Matches[1]
            $hour = [int]$Matches[2]
            $minute = [int]$Matches[3]
            $time = Get-Date -Hour $hour -Minute $minute -Second 0
            try {
                $day = [System.DayOfWeek]$dayName
            } catch {
                throw "Invalid day of week: '$dayName'. Use Monday, Tuesday, etc."
            }
            return New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $time
        }
        '^hourly$' {
            $now = Get-Date
            return New-ScheduledTaskTrigger -Once -At $now `
                -RepetitionInterval (New-TimeSpan -Hours 1) `
                -RepetitionDuration ([TimeSpan]::MaxValue)
        }
        '^every\s+(\d+)m$' {
            $minutes = [int]$Matches[1]
            if ($minutes -lt 1) { throw "Interval must be at least 1 minute" }
            $now = Get-Date
            return New-ScheduledTaskTrigger -Once -At $now `
                -RepetitionInterval (New-TimeSpan -Minutes $minutes) `
                -RepetitionDuration ([TimeSpan]::MaxValue)
        }
        '^every\s+(\d+)h$' {
            $hours = [int]$Matches[1]
            if ($hours -lt 1) { throw "Interval must be at least 1 hour" }
            $now = Get-Date
            return New-ScheduledTaskTrigger -Once -At $now `
                -RepetitionInterval (New-TimeSpan -Hours $hours) `
                -RepetitionDuration ([TimeSpan]::MaxValue)
        }
        '^once\s+(\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2})$' {
            $dateTime = [DateTime]::ParseExact("$($Matches[1]) $($Matches[2])", 'yyyy-MM-dd H:mm', $null)
            return New-ScheduledTaskTrigger -Once -At $dateTime
        }
        '^startup$' {
            return New-ScheduledTaskTrigger -AtStartup
        }
        '^logon$' {
            return New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        }
        default {
            throw @"
Unknown schedule format: '$ScheduleStr'
Supported formats:
  daily HH:MM          - Every day at time (e.g., daily 08:00)
  weekly DAY HH:MM     - Weekly on day (e.g., weekly Monday 09:00)
  hourly               - Every hour
  every Nm             - Every N minutes (e.g., every 30m)
  every Nh             - Every N hours (e.g., every 4h)
  once YYYY-MM-DD HH:MM - One-time (e.g., once 2026-03-15 14:00)
  startup              - At system startup
  logon                - At user logon
"@
        }
    }
}

# --- Helper: Format relative time ---
function Format-RelativeTime {
    param([string]$DateTimeStr)
    if (-not $DateTimeStr) { return 'never' }
    try {
        $dt = [DateTime]::Parse($DateTimeStr)
        $span = (Get-Date) - $dt
        if ($span.TotalMinutes -lt 1) { return 'just now' }
        if ($span.TotalMinutes -lt 60) { return "$([Math]::Floor($span.TotalMinutes))m ago" }
        if ($span.TotalHours -lt 24) { return "$([Math]::Floor($span.TotalHours))h ago" }
        if ($span.TotalDays -lt 30) { return "$([Math]::Floor($span.TotalDays))d ago" }
        return $dt.ToString('yyyy-MM-dd')
    } catch {
        return $DateTimeStr
    }
}

# --- Helper: Get Task Scheduler task info ---
function Get-ClaudeTask {
    param([string]$TaskName)
    try {
        return Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
    } catch {
        return $null
    }
}

# ============================================================
# COMMANDS
# ============================================================

switch ($Command) {

    'create' {
        if (-not (Test-JobName $Name)) { exit 1 }
        if (-not $Prompt) { Write-Error "Prompt is required. Use -Prompt to specify."; exit 1 }
        if (-not $Schedule) { Write-Error "Schedule is required. Use -Schedule to specify."; exit 1 }

        $jobFile = Join-Path $JobsDir "$Name.json"
        if (Test-Path $jobFile) {
            Write-Error "Job '$Name' already exists. Delete it first or choose a different name."
            exit 1
        }

        # Validate schedule before creating anything
        Write-Host "Parsing schedule: $Schedule"
        $trigger = ConvertTo-ScheduledTaskTrigger $Schedule

        # Build job definition
        $job = [ordered]@{
            schemaVersion        = 1
            name                 = $Name
            description          = if ($Description) { $Description } else { '' }
            prompt               = $Prompt
            schedule             = $Schedule
            enabled              = $true
            maxBudgetUsd         = if ($MaxBudget -gt 0) { $MaxBudget } else { 5.0 }
            allowedTools         = if ($AllowedTools) { @($AllowedTools) } else { @() }
            disallowedTools      = if ($DisallowedTools) { @($DisallowedTools) } else { @() }
            model                = if ($Model) { $Model } else { 'sonnet' }
            effort               = if ($Effort) { $Effort } else { '' }
            workingDirectory     = if ($WorkDir) { $WorkDir } else { '~' }
            mcpConfig            = if ($McpConfig) { $McpConfig } else { $null }
            appendSystemPrompt   = if ($AppendSystemPrompt) { $AppendSystemPrompt } else { $null }
            logRetentionDays     = $LogRetention
            noSessionPersistence = if ($NoSessionPersistence) { $true } else { $true }
            createdAt            = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            lastRunAt            = $null
            lastRunStatus        = $null
            lastRunDurationSec   = $null
        }

        # Write job JSON
        $job | ConvertTo-Json -Depth 10 | Set-Content -Path $jobFile -Encoding utf8
        Write-Host "Created job definition: $jobFile"

        # Register Task Scheduler entry
        $action = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument "-ExecutionPolicy Bypass -NoProfile -NonInteractive -File `"$RunnerPath`" -JobName `"$Name`""

        $principal = New-ScheduledTaskPrincipal `
            -UserId $env:USERNAME `
            -LogonType Interactive `
            -RunLevel Limited

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2)

        Register-ScheduledTask `
            -TaskName $Name `
            -TaskPath $TaskPath `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description $(if ($Description) { $Description } else { "Claude Scheduler job: $Name" }) | Out-Null

        Write-Host ""
        Write-Host "Job '$Name' created successfully!"
        Write-Host "  Schedule : $Schedule"
        Write-Host "  Model    : $($job.model)"
        Write-Host "  Budget   : `$$($job.maxBudgetUsd)"
        Write-Host "  Run now  : claude-scheduler run -Name $Name"
        Write-Host "  Disable  : claude-scheduler disable -Name $Name"
    }

    'list' {
        $jobFiles = @(Get-ChildItem -Path $JobsDir -Filter '*.json' -ErrorAction SilentlyContinue)
        if ($jobFiles.Count -eq 0) {
            Write-Host "No jobs found."
            Write-Host "Create one with: claude-scheduler create -Name <name> -Prompt <prompt> -Schedule <schedule>"
            exit 0
        }

        $rows = @()
        foreach ($file in $jobFiles) {
            $job = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            $taskName = $job.name
            $task = Get-ClaudeTask $taskName

            $schedulerState = if ($task) { $task.State.ToString() } else { 'NOT REGISTERED' }

            # Detect sync issues
            $syncWarning = ''
            if (-not $task) {
                $syncWarning = ' [!]'
            } elseif ($task.State -eq 'Disabled' -and $job.enabled -eq $true) {
                $syncWarning = ' [sync]'
            } elseif ($task.State -ne 'Disabled' -and $job.enabled -eq $false) {
                $syncWarning = ' [sync]'
            }

            $rows += [PSCustomObject]@{
                Name     = "$taskName$syncWarning"
                Schedule = $job.schedule
                Enabled  = if ($job.enabled) { 'Yes' } else { 'No' }
                Model    = if ($job.model) { $job.model } else { '-' }
                LastRun  = Format-RelativeTime $job.lastRunAt
                Status   = if ($job.lastRunStatus) { $job.lastRunStatus } else { 'never' }
                Budget   = if ($job.maxBudgetUsd) { "`$$($job.maxBudgetUsd)" } else { '-' }
            }
        }

        $rows | Format-Table -AutoSize

        # Show sync warnings
        $warnings = $rows | Where-Object { $_.Name -match '\[' }
        if ($warnings) {
            Write-Host ""
            Write-Host "Warnings:"
            Write-Host "  [!]    = Job JSON exists but no Task Scheduler entry found"
            Write-Host "  [sync] = Task Scheduler state doesn't match job JSON enabled state"
        }
    }

    'enable' {
        if (-not (Test-JobName $Name)) { exit 1 }
        $jobFile = Join-Path $JobsDir "$Name.json"
        if (-not (Test-Path $jobFile)) {
            Write-Error "Job '$Name' not found."
            exit 1
        }

        $job = Get-Content -Path $jobFile -Raw | ConvertFrom-Json
        $job | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $true -Force
        $job | ConvertTo-Json -Depth 10 | Set-Content -Path $jobFile -Encoding utf8

        try {
            Enable-ScheduledTask -TaskPath $TaskPath -TaskName $Name | Out-Null
        } catch {
            Write-Host "Warning: Could not enable Task Scheduler entry: $_"
        }

        Write-Host "Enabled job '$Name'"
    }

    'disable' {
        if (-not (Test-JobName $Name)) { exit 1 }
        $jobFile = Join-Path $JobsDir "$Name.json"
        if (-not (Test-Path $jobFile)) {
            Write-Error "Job '$Name' not found."
            exit 1
        }

        $job = Get-Content -Path $jobFile -Raw | ConvertFrom-Json
        $job | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $false -Force
        $job | ConvertTo-Json -Depth 10 | Set-Content -Path $jobFile -Encoding utf8

        try {
            Disable-ScheduledTask -TaskPath $TaskPath -TaskName $Name | Out-Null
        } catch {
            Write-Host "Warning: Could not disable Task Scheduler entry: $_"
        }

        Write-Host "Disabled job '$Name' (preserved, will not run until re-enabled)"
    }

    'run' {
        if (-not (Test-JobName $Name)) { exit 1 }
        $jobFile = Join-Path $JobsDir "$Name.json"
        if (-not (Test-Path $jobFile)) {
            Write-Error "Job '$Name' not found."
            exit 1
        }

        if ($Background) {
            # Run via Task Scheduler (same execution context as scheduled runs)
            try {
                Start-ScheduledTask -TaskPath $TaskPath -TaskName $Name
                Write-Host "Started job '$Name' in background via Task Scheduler."
                Write-Host "Check logs: claude-scheduler logs -Name $Name"
            } catch {
                Write-Error "Could not start task: $_"
                exit 1
            }
        } else {
            # Run inline (visible output)
            if (-not (Test-Path $RunnerPath)) {
                Write-Error "Runner not found at: $RunnerPath"
                exit 1
            }

            Write-Host "Running job '$Name' inline..."
            Write-Host "---"
            & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $RunnerPath -JobName $Name
            $runExitCode = $LASTEXITCODE
            Write-Host "---"

            if ($runExitCode -eq 0) {
                Write-Host "Job '$Name' completed successfully."
            } else {
                Write-Host "Job '$Name' failed with exit code $runExitCode."
            }
        }
    }

    'delete' {
        if (-not (Test-JobName $Name)) { exit 1 }
        $jobFile = Join-Path $JobsDir "$Name.json"
        if (-not (Test-Path $jobFile)) {
            Write-Error "Job '$Name' not found."
            exit 1
        }

        Write-Host "Delete job '$Name' and its Task Scheduler entry?"
        Write-Host "Logs will be preserved at: $(Join-Path $LogsDir $Name)"
        $confirm = Read-Host "Type 'yes' to confirm"

        if ($confirm -ne 'yes') {
            Write-Host "Cancelled."
            exit 0
        }

        # Remove Task Scheduler entry
        try {
            Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $Name -Confirm:$false
            Write-Host "Removed Task Scheduler entry."
        } catch {
            Write-Host "Warning: Could not remove Task Scheduler entry: $_"
        }

        # Remove job JSON
        Remove-Item -Path $jobFile -Force
        Write-Host "Removed job definition."
        Write-Host "Deleted job '$Name'. Logs preserved."
    }

    'logs' {
        if (-not (Test-JobName $Name)) { exit 1 }
        $jobLogDir = Join-Path $LogsDir $Name

        if (-not (Test-Path $jobLogDir)) {
            Write-Host "No logs found for job '$Name'."
            exit 0
        }

        $logFiles = @(Get-ChildItem -Path $jobLogDir -Filter '*.log' | Sort-Object Name -Descending)

        if ($logFiles.Count -eq 0) {
            Write-Host "No log files found for job '$Name'."
            exit 0
        }

        $latest = $logFiles[0]
        Write-Host "=== Latest log: $($latest.Name) ==="
        Write-Host "Log file: $($latest.FullName)"
        Write-Host "Total log files: $($logFiles.Count) (oldest: $($logFiles[-1].Name), newest: $($logFiles[0].Name))"
        Write-Host "---"

        Get-Content -Path $latest.FullName -Tail $Tail
    }

    'purge-logs' {
        $targetDirs = @()
        if ($Name) {
            $targetDirs += Join-Path $LogsDir $Name
        } else {
            $targetDirs = @(Get-ChildItem -Path $LogsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }

        if ($targetDirs.Count -eq 0) {
            Write-Host "No log directories found."
            exit 0
        }

        $totalPurged = 0
        $totalJobs = 0
        $cutoff = (Get-Date).AddDays(-$Days)

        foreach ($dir in $targetDirs) {
            if (-not (Test-Path $dir)) { continue }
            $old = Get-ChildItem -Path $dir -Filter '*.log' | Where-Object { $_.LastWriteTime -lt $cutoff }
            if ($old) {
                $count = ($old | Measure-Object).Count
                $old | Remove-Item -Force
                $totalPurged += $count
                $totalJobs++
            }
        }

        Write-Host "Purged $totalPurged log files across $totalJobs jobs (older than $Days days)"
    }

    'status' {
        if (-not (Test-JobName $Name)) { exit 1 }
        $jobFile = Join-Path $JobsDir "$Name.json"
        if (-not (Test-Path $jobFile)) {
            Write-Error "Job '$Name' not found."
            exit 1
        }

        $job = Get-Content -Path $jobFile -Raw | ConvertFrom-Json
        $task = Get-ClaudeTask $Name

        # Log stats
        $jobLogDir = Join-Path $LogsDir $Name
        $logCount = 0
        $logSize = 0
        $oldestLog = '-'
        $newestLog = '-'
        if (Test-Path $jobLogDir) {
            $logFiles = @(Get-ChildItem -Path $jobLogDir -Filter '*.log' -ErrorAction SilentlyContinue)
            if ($logFiles.Count -gt 0) {
                $logCount = $logFiles.Count
                $logSize = ($logFiles | Measure-Object -Property Length -Sum).Sum
                $sorted = @($logFiles | Sort-Object Name)
                $oldestLog = $sorted[0].Name -replace '\.log$', ''
                $newestLog = $sorted[-1].Name -replace '\.log$', ''
            }
        }

        # Task Scheduler info
        $taskState = if ($task) { $task.State.ToString() } else { 'NOT REGISTERED' }
        $nextRun = '-'
        if ($task) {
            try {
                $taskInfo = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $Name -ErrorAction SilentlyContinue
                if ($taskInfo -and $taskInfo.NextRunTime -and $taskInfo.NextRunTime -ne [DateTime]::MinValue) {
                    $nextRun = $taskInfo.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss')
                }
            } catch {}
        }

        Write-Host ""
        Write-Host "  Job          : $($job.name)"
        Write-Host "  Description  : $(if ($job.description) { $job.description } else { '-' })"
        Write-Host "  Schedule     : $($job.schedule)"
        Write-Host "  Enabled      : $(if ($job.enabled) { 'Yes' } else { 'No' })"
        Write-Host "  Model        : $(if ($job.model) { $job.model } else { 'default' })"
        Write-Host "  Budget       : $(if ($job.maxBudgetUsd) { "`$$($job.maxBudgetUsd)" } else { '-' })"
        Write-Host "  Effort       : $(if ($job.effort) { $job.effort } else { '-' })"
        Write-Host "  Working Dir  : $(if ($job.workingDirectory) { $job.workingDirectory } else { '~' })"
        Write-Host "  Log Retention: $($job.logRetentionDays) days"
        Write-Host ""
        Write-Host "  Task State   : $taskState"
        Write-Host "  Next Run     : $nextRun"
        Write-Host "  Last Run     : $(if ($job.lastRunAt) { "$($job.lastRunAt) ($($job.lastRunStatus), $($job.lastRunDurationSec)s)" } else { 'never' })"
        Write-Host ""
        Write-Host "  Logs         : $logCount files ($([Math]::Round($logSize / 1KB, 1)) KB)"
        Write-Host "  Oldest Log   : $oldestLog"
        Write-Host "  Newest Log   : $newestLog"
        Write-Host ""
    }

    default {
        Write-Host "Claude Scheduler - Manage scheduled Claude Code jobs"
        Write-Host ""
        Write-Host "Usage: claude-scheduler <command> [options]"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  create     Create a new scheduled job"
        Write-Host "  list       List all jobs with status"
        Write-Host "  enable     Enable a disabled job"
        Write-Host "  disable    Temporarily disable a job (preserves it)"
        Write-Host "  run        Run a job immediately"
        Write-Host "  delete     Delete a job permanently"
        Write-Host "  logs       View latest log for a job"
        Write-Host "  purge-logs Purge old log files"
        Write-Host "  status     Show detailed job status"
        Write-Host ""
        Write-Host "Examples:"
        Write-Host '  claude-scheduler create -Name "daily-summary" -Prompt "Summarize HN" -Schedule "daily 09:00"'
        Write-Host '  claude-scheduler list'
        Write-Host '  claude-scheduler run -Name "daily-summary"'
        Write-Host '  claude-scheduler disable -Name "daily-summary"'
        Write-Host ""
        Write-Host "Schedule formats:"
        Write-Host "  daily HH:MM, weekly DAY HH:MM, hourly, every Nm, every Nh,"
        Write-Host "  once YYYY-MM-DD HH:MM, startup, logon"
    }
}
