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
    [ValidateSet('create', 'list', 'update', 'enable', 'disable', 'run', 'delete', 'logs', 'purge-logs', 'status', 'setup-notify', 'test-notify')]
    [string]$Command,

    [string]$Name,
    [string]$Prompt,
    [string]$Schedule,
    [string]$Description,
    [string]$Model,
    [double]$MaxBudget = -1,
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
    [int]$Days = 30,

    # Setup-notify parameters
    [string]$NotifyCommand,
    [string[]]$NotifyArgs,
    [string[]]$NotifyOn,
    [switch]$Disable,

    # Delete parameters
    [switch]$KeepLogs
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

# --- Helper: Register a Claude scheduled task ---
function Register-ClaudeScheduledTask {
    param([string]$TaskName, [object]$Trigger, [string]$Description)
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-ExecutionPolicy Bypass -NoProfile -NonInteractive -File `"$RunnerPath`" -JobName `"$TaskName`""
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
    $desc = if ($Description) { $Description } else { "Claude Scheduler job: $TaskName" }
    Register-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $TaskPath `
        -Action $action `
        -Trigger $Trigger `
        -Principal $principal `
        -Settings $settings `
        -Description $desc | Out-Null
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
            maxBudgetUsd         = if ($MaxBudget -ge 0) { $MaxBudget } else { $null }
            allowedTools         = if ($AllowedTools) { @($AllowedTools) } else { @() }
            disallowedTools      = if ($DisallowedTools) { @($DisallowedTools) } else { @() }
            model                = if ($Model) { $Model } else { 'sonnet' }
            effort               = if ($Effort) { $Effort } else { '' }
            workingDirectory     = if ($WorkDir) { $WorkDir } else { '~' }
            mcpConfig            = if ($McpConfig) { $McpConfig } else { $null }
            appendSystemPrompt   = if ($AppendSystemPrompt) { $AppendSystemPrompt } else { $null }
            logRetentionDays     = $LogRetention
            noSessionPersistence = $true
            createdAt            = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            lastRunAt            = $null
            lastRunStatus        = $null
            lastRunDurationSec   = $null
        }

        # Write job JSON
        $job | ConvertTo-Json -Depth 10 | Set-Content -Path $jobFile -Encoding utf8
        Write-Host "Created job definition: $jobFile"

        # Register Task Scheduler entry
        Register-ClaudeScheduledTask -TaskName $Name -Trigger $trigger `
            -Description $(if ($Description) { $Description } else { $null })

        Write-Host ""
        Write-Host "Job '$Name' created successfully!"
        Write-Host "  Schedule : $Schedule"
        Write-Host "  Model    : $($job.model)"
        if ($job.maxBudgetUsd) { Write-Host "  Budget   : `$$($job.maxBudgetUsd)" }
        if ($job.effort) { Write-Host "  Effort   : $($job.effort)" }
        Write-Host "  Run now  : claude-scheduler run -Name $Name"
        Write-Host "  Disable  : claude-scheduler disable -Name $Name"
    }

    'update' {
        if (-not (Test-JobName $Name)) { exit 1 }
        $jobFile = Join-Path $JobsDir "$Name.json"
        if (-not (Test-Path $jobFile)) {
            Write-Error "Job '$Name' not found. Use 'create' to make a new job."
            exit 1
        }

        # Check that at least one updatable field was provided
        $updatableParams = @('Schedule', 'Prompt', 'Description', 'Model', 'MaxBudget',
                             'Effort', 'WorkDir', 'AllowedTools', 'DisallowedTools',
                             'LogRetention', 'McpConfig', 'AppendSystemPrompt')
        $hasUpdate = $false
        foreach ($p in $updatableParams) {
            if ($PSBoundParameters.ContainsKey($p)) { $hasUpdate = $true; break }
        }
        if (-not $hasUpdate) {
            Write-Error "No fields to update. Provide at least one of: -Schedule, -Prompt, -Model, -Description, -Effort, -MaxBudget, -WorkDir, -AllowedTools, -DisallowedTools, -LogRetention, -McpConfig, -AppendSystemPrompt"
            exit 1
        }

        # If schedule is being changed, validate it first (fail-fast)
        $trigger = $null
        if ($PSBoundParameters.ContainsKey('Schedule')) {
            Write-Host "Parsing schedule: $Schedule"
            $trigger = ConvertTo-ScheduledTaskTrigger $Schedule
        }

        # Load existing job
        $job = Get-Content -Path $jobFile -Raw | ConvertFrom-Json

        # Track changes for summary
        $changes = @()

        # Update each field that was explicitly provided
        if ($PSBoundParameters.ContainsKey('Schedule')) {
            $changes += "Schedule: '$($job.schedule)' -> '$Schedule'"
            $job | Add-Member -NotePropertyName 'schedule' -NotePropertyValue $Schedule -Force
        }
        if ($PSBoundParameters.ContainsKey('Prompt')) {
            $changes += "Prompt: updated"
            $job | Add-Member -NotePropertyName 'prompt' -NotePropertyValue $Prompt -Force
        }
        if ($PSBoundParameters.ContainsKey('Description')) {
            $changes += "Description: updated"
            $job | Add-Member -NotePropertyName 'description' -NotePropertyValue $(if ($Description) { $Description } else { '' }) -Force
        }
        if ($PSBoundParameters.ContainsKey('Model')) {
            $changes += "Model: '$($job.model)' -> '$Model'"
            $job | Add-Member -NotePropertyName 'model' -NotePropertyValue $Model -Force
        }
        if ($PSBoundParameters.ContainsKey('MaxBudget')) {
            $budgetVal = if ($MaxBudget -ge 0) { $MaxBudget } else { $null }
            $oldBudget = if ($job.maxBudgetUsd) { "`$$($job.maxBudgetUsd)" } else { 'none' }
            $newBudget = if ($budgetVal) { "`$$budgetVal" } else { 'none' }
            $changes += "Budget: $oldBudget -> $newBudget"
            $job | Add-Member -NotePropertyName 'maxBudgetUsd' -NotePropertyValue $budgetVal -Force
        }
        if ($PSBoundParameters.ContainsKey('Effort')) {
            $changes += "Effort: '$($job.effort)' -> '$Effort'"
            $job | Add-Member -NotePropertyName 'effort' -NotePropertyValue $(if ($Effort) { $Effort } else { '' }) -Force
        }
        if ($PSBoundParameters.ContainsKey('WorkDir')) {
            $changes += "WorkDir: updated"
            $job | Add-Member -NotePropertyName 'workingDirectory' -NotePropertyValue $(if ($WorkDir) { $WorkDir } else { '~' }) -Force
        }
        if ($PSBoundParameters.ContainsKey('AllowedTools')) {
            $changes += "AllowedTools: updated"
            $job | Add-Member -NotePropertyName 'allowedTools' -NotePropertyValue @($AllowedTools) -Force
        }
        if ($PSBoundParameters.ContainsKey('DisallowedTools')) {
            $changes += "DisallowedTools: updated"
            $job | Add-Member -NotePropertyName 'disallowedTools' -NotePropertyValue @($DisallowedTools) -Force
        }
        if ($PSBoundParameters.ContainsKey('LogRetention')) {
            $changes += "LogRetention: $($job.logRetentionDays) -> $LogRetention days"
            $job | Add-Member -NotePropertyName 'logRetentionDays' -NotePropertyValue $LogRetention -Force
        }
        if ($PSBoundParameters.ContainsKey('McpConfig')) {
            $changes += "McpConfig: updated"
            $job | Add-Member -NotePropertyName 'mcpConfig' -NotePropertyValue $(if ($McpConfig) { $McpConfig } else { $null }) -Force
        }
        if ($PSBoundParameters.ContainsKey('AppendSystemPrompt')) {
            $changes += "AppendSystemPrompt: updated"
            $job | Add-Member -NotePropertyName 'appendSystemPrompt' -NotePropertyValue $(if ($AppendSystemPrompt) { $AppendSystemPrompt } else { $null }) -Force
        }

        # Auto-enable if schedule changed and job is disabled
        $wasReEnabled = $false
        if ($PSBoundParameters.ContainsKey('Schedule') -and $job.enabled -eq $false) {
            $job | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $true -Force
            $wasReEnabled = $true
            $changes += "Enabled: No -> Yes (auto-enabled with new schedule)"
        }

        # Save updated JSON
        $job | ConvertTo-Json -Depth 10 | Set-Content -Path $jobFile -Encoding utf8

        # Re-register Task Scheduler if schedule changed or job was re-enabled
        if ($PSBoundParameters.ContainsKey('Schedule') -or $wasReEnabled) {
            if (-not $trigger) {
                $trigger = ConvertTo-ScheduledTaskTrigger $job.schedule
            }

            try {
                Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $Name -Confirm:$false
            } catch {
                Write-Host "Warning: Could not remove old Task Scheduler entry: $_"
            }

            $desc = if ($job.description) { $job.description } else { $null }
            Register-ClaudeScheduledTask -TaskName $Name -Trigger $trigger -Description $desc
            Write-Host "Task Scheduler entry updated."

            if ($wasReEnabled) {
                Enable-ScheduledTask -TaskPath $TaskPath -TaskName $Name -ErrorAction SilentlyContinue
            }
        }

        # Summary
        Write-Host ""
        Write-Host "Updated job '$Name':"
        foreach ($change in $changes) {
            Write-Host "  - $change"
        }
        if ($wasReEnabled) {
            Write-Host ""
            Write-Host "  Job was disabled and has been re-enabled with the new schedule."
        }
        Write-Host ""
        Write-Host "  Status : claude-scheduler status -Name $Name"
        Write-Host "  Run now: claude-scheduler run -Name $Name"
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

        $jobLogDir = Join-Path $LogsDir $Name
        $hasLogs = Test-Path $jobLogDir

        Write-Host "Delete job '$Name'?"
        Write-Host "  - Task Scheduler entry"
        Write-Host "  - Job definition ($jobFile)"
        if ($hasLogs -and -not $KeepLogs) {
            Write-Host "  - All logs ($jobLogDir)"
        } elseif ($hasLogs -and $KeepLogs) {
            Write-Host "  - Logs will be PRESERVED at: $jobLogDir"
        }
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

        # Remove logs (unless -KeepLogs)
        if (-not $KeepLogs -and $hasLogs) {
            Remove-Item -Path $jobLogDir -Recurse -Force
            Write-Host "Removed logs."
        } elseif ($KeepLogs -and $hasLogs) {
            Write-Host "Logs preserved at: $jobLogDir"
        }

        Write-Host "Deleted job '$Name'."
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
        if ($job.PSObject.Properties['maxBudgetUsd'] -and $null -ne $job.maxBudgetUsd) {
            Write-Host "  Budget       : `$$($job.maxBudgetUsd)"
        }
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

    'setup-notify' {
        $notifyFile = Join-Path $SchedulerDir 'notify.json'

        # Disable notifications
        if ($Disable) {
            if (Test-Path $notifyFile) {
                $config = Get-Content -Path $notifyFile -Raw | ConvertFrom-Json
                $config | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $false -Force
                $config | ConvertTo-Json -Depth 10 | Set-Content -Path $notifyFile -Encoding utf8
                Write-Host "Notifications disabled."
            } else {
                Write-Host "No notification config found. Nothing to disable."
            }
            exit 0
        }

        # Show current config if no params provided
        if (-not $NotifyCommand) {
            if (Test-Path $notifyFile) {
                $config = Get-Content -Path $notifyFile -Raw | ConvertFrom-Json
                Write-Host "=== Notification Config ==="
                Write-Host "  Enabled  : $($config.enabled)"
                Write-Host "  Command  : $($config.command)"
                Write-Host "  Args     : $($config.args -join ' ')"
                Write-Host "  Notify On: $($config.notifyOn -join ', ')"
                Write-Host ""
                Write-Host "Test: claude-scheduler test-notify"
                Write-Host "Disable: claude-scheduler setup-notify -Disable"
            } else {
                Write-Host "No notification config found."
                Write-Host ""
                Write-Host "Set up with:"
                Write-Host '  claude-scheduler setup-notify -NotifyCommand <cmd> -NotifyArgs <args>'
                Write-Host ""
                Write-Host "The notification command receives {{message}} replaced with failure details."
            }
            exit 0
        }

        # Validate args contain {{message}} placeholder
        $hasPlaceholder = $false
        foreach ($arg in $NotifyArgs) {
            if ($arg -match '\{\{message\}\}') { $hasPlaceholder = $true; break }
        }
        if (-not $hasPlaceholder) {
            Write-Host "WARNING: None of your -NotifyArgs contain '{{message}}'." -ForegroundColor Yellow
            Write-Host "The notification will fire but won't include failure details."
            Write-Host ""
        }

        # Build config
        $notifyOnValues = if ($NotifyOn) { @($NotifyOn) } else { @('job-failure', 'all-failures') }

        $config = [ordered]@{
            enabled   = $true
            method    = 'command'
            command   = $NotifyCommand
            args      = @($NotifyArgs)
            notifyOn  = $notifyOnValues
        }

        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $notifyFile -Encoding utf8

        Write-Host "Notification config saved to: $notifyFile"
        Write-Host "  Command  : $NotifyCommand"
        Write-Host "  Args     : $($NotifyArgs -join ' ')"
        Write-Host "  Notify On: $($notifyOnValues -join ', ')"
        Write-Host ""
        Write-Host "Test it: claude-scheduler test-notify"
    }

    'test-notify' {
        $notifyFile = Join-Path $SchedulerDir 'notify.json'
        if (-not (Test-Path $notifyFile)) {
            Write-Host "No notification config found. Run setup-notify first."
            exit 1
        }

        $config = Get-Content -Path $notifyFile -Raw | ConvertFrom-Json
        if (-not $config.enabled) {
            Write-Host "Notifications are disabled. Enable with: claude-scheduler setup-notify -NotifyCommand ..."
            exit 1
        }

        Write-Host "Sending test notification..."
        $testMessage = "[Claude Scheduler] Test notification - if you see this, notifications are working!"

        try {
            $cmdArgs = @($config.args) | ForEach-Object { $_ -replace '\{\{message\}\}', $testMessage }
            & $config.command @cmdArgs 2>&1 | Out-Null
            Write-Host "Test notification sent via $($config.command)"
            Write-Host "Check your device for the message."
        } catch {
            Write-Host "Failed to send test notification: $_" -ForegroundColor Red
            Write-Host "Check your NotifyCommand path and NotifyArgs."
            exit 1
        }
    }

    default {
        Write-Host "Claude Scheduler - Manage scheduled Claude Code jobs"
        Write-Host ""
        Write-Host "Usage: claude-scheduler <command> [options]"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  create     Create a new scheduled job"
        Write-Host "  list       List all jobs with status"
        Write-Host "  update     Update an existing job (schedule, prompt, model, etc.)"
        Write-Host "  enable     Enable a disabled job"
        Write-Host "  disable    Temporarily disable a job (preserves it)"
        Write-Host "  run        Run a job immediately"
        Write-Host "  delete     Delete a job permanently (use -KeepLogs to preserve logs)"
        Write-Host "  logs       View latest log for a job"
        Write-Host "  purge-logs Purge old log files"
        Write-Host "  status     Show detailed job status"
        Write-Host ""
        Write-Host "Examples:"
        Write-Host '  claude-scheduler create -Name "daily-summary" -Prompt "Summarize HN" -Schedule "daily 09:00"'
        Write-Host '  claude-scheduler update -Name "daily-summary" -Schedule "weekly Monday 09:00"'
        Write-Host '  claude-scheduler list'
        Write-Host '  claude-scheduler run -Name "daily-summary"'
        Write-Host '  claude-scheduler disable -Name "daily-summary"'
        Write-Host ""
        Write-Host "Schedule formats:"
        Write-Host "  daily HH:MM, weekly DAY HH:MM, hourly, every Nm, every Nh,"
        Write-Host "  once YYYY-MM-DD HH:MM, startup, logon"
    }
}
