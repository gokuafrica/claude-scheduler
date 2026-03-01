#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Scheduler Runner - Executes a scheduled Claude Code job.
.DESCRIPTION
    Called by Windows Task Scheduler to run a Claude Code job defined in a JSON file.
    Handles prompt enhancement, logging, log purging, and status tracking.
.PARAMETER JobName
    Name of the job to run (matches the JSON filename in the jobs/ directory).
#>
param(
    [Parameter(Mandatory)]
    [string]$JobName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- Path Resolution ---
$SchedulerDir = Join-Path $env:USERPROFILE '.claude\scheduler'
$JobsDir = Join-Path $SchedulerDir 'jobs'
$LogsDir = Join-Path $SchedulerDir 'logs'
$JobFile = Join-Path $JobsDir "$JobName.json"

# --- Helper: Expand ~ to $env:USERPROFILE ---
function Expand-TildePath {
    param([string]$Path)
    if (-not $Path) { return $null }
    if ($Path -eq '~') { return $env:USERPROFILE }
    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return Join-Path $env:USERPROFILE $Path.Substring(2)
    }
    return $Path
}

# --- Helper: Write to log file and console ---
$Script:LogFile = $null
function Write-Log {
    param([string]$Message, [switch]$IsError)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = if ($IsError) { 'ERROR' } else { 'INFO' }
    $line = "[$timestamp] [$prefix] $Message"
    Write-Host $line
    if ($Script:LogFile) {
        $line | Out-File -Append -FilePath $Script:LogFile -Encoding utf8
    }
}

# --- Helper: Atomic JSON write (temp file + rename) ---
function Write-JobJson {
    param([object]$Job, [string]$Path)
    $tempFile = "$Path.tmp"
    $Job | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding utf8
    Move-Item -Path $tempFile -Destination $Path -Force
}

# --- Helper: Send failure notification to user's phone ---
function Send-FailureNotification {
    param([string]$JobName, [string]$Reason)
    try {
        $notifyFile = Join-Path $SchedulerDir 'notify.json'
        if (-not (Test-Path $notifyFile)) { return }

        $config = Get-Content -Path $notifyFile -Raw | ConvertFrom-Json
        if (-not $config.enabled) { return }

        # Check if this failure type should trigger a notification
        $notifyOn = @($config.notifyOn)
        $shouldNotify = $false
        if ('all-failures' -in $notifyOn) { $shouldNotify = $true }
        if ('job-failure' -in $notifyOn) { $shouldNotify = $true }
        if (-not $shouldNotify) { return }

        # Build message with actionable info
        $message = "[Claude Scheduler] Job '$JobName' failed: $Reason`nRe-run: claude-scheduler run -Name $JobName"

        # Execute notification command with {{message}} placeholder replaced
        $cmdArgs = @($config.args) | ForEach-Object { $_ -replace '\{\{message\}\}', $message }
        & $config.command @cmdArgs 2>&1 | Out-Null

        Write-Log "Notification sent via $($config.command)"
    } catch {
        # Non-fatal — notification failure should never block job execution
        Write-Log "Failed to send notification: $_" -IsError
    }
}

# --- Main Execution ---
try {
    # 1. Validate job file exists
    if (-not (Test-Path $JobFile)) {
        Write-Error "Job file not found: $JobFile"
        exit 1
    }

    # 2. Read and validate job definition
    $job = Get-Content -Path $JobFile -Raw | ConvertFrom-Json

    if (-not $job.name) { Write-Error "Job missing required field: name"; exit 1 }
    if (-not $job.prompt) { Write-Error "Job missing required field: prompt"; exit 1 }

    # 3. Check enabled flag
    if ($job.PSObject.Properties['enabled'] -and $job.enabled -eq $false) {
        Write-Host "Job '$JobName' is disabled. Skipping."
        exit 0
    }

    # 4. Set up logging
    $jobLogDir = Join-Path $LogsDir $JobName
    if (-not (Test-Path $jobLogDir)) {
        New-Item -ItemType Directory -Path $jobLogDir -Force | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $Script:LogFile = Join-Path $jobLogDir "$timestamp.log"

    Write-Log "=== Claude Scheduler Runner ==="
    Write-Log "Job: $JobName"
    Write-Log "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "Log file: $($Script:LogFile)"

    # 5. Purge old logs
    $retentionDays = if ($job.PSObject.Properties['logRetentionDays'] -and $job.logRetentionDays) {
        $job.logRetentionDays
    } else { 30 }

    $cutoff = (Get-Date).AddDays(-$retentionDays)
    $oldLogs = Get-ChildItem -Path $jobLogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }

    if ($oldLogs) {
        $count = ($oldLogs | Measure-Object).Count
        $oldLogs | Remove-Item -Force
        Write-Log "Purged $count log files older than $retentionDays days"
    }

    # 6. Ensure PATH includes npm and Node directories
    $npmDir = Join-Path $env:APPDATA 'npm'
    $nodeDir = 'C:\Program Files\nodejs'
    $pathDirs = $env:PATH -split ';'
    $additions = @()
    if ($npmDir -notin $pathDirs) { $additions += $npmDir }
    if ($nodeDir -notin $pathDirs) { $additions += $nodeDir }
    if ($additions.Count -gt 0) {
        $env:PATH = ($additions -join ';') + ';' + $env:PATH
        Write-Log "Added to PATH: $($additions -join ', ')"
    }

    # 7. Verify claude CLI is available
    try {
        $null = & claude --version 2>&1
    } catch {
        Write-Log "Claude CLI not found. Ensure it is installed and on PATH." -IsError
        $job | Add-Member -NotePropertyName 'lastRunAt' -NotePropertyValue (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') -Force
        $job | Add-Member -NotePropertyName 'lastRunStatus' -NotePropertyValue 'error:claude-not-found' -Force
        Write-JobJson -Job $job -Path $JobFile
        exit 1
    }

    # 8. Resolve working directory
    $workDir = if ($job.PSObject.Properties['workingDirectory'] -and $job.workingDirectory) {
        Expand-TildePath $job.workingDirectory
    } else {
        $env:USERPROFILE
    }

    if (-not (Test-Path $workDir)) {
        Write-Log "Working directory not found: $workDir. Falling back to home directory." -IsError
        $workDir = $env:USERPROFILE
    }

    Write-Log "Working directory: $workDir"

    # 9. Build autonomy system prompt
    $autonomyPrompt = @"
AUTONOMOUS SCHEDULED TASK MODE:
- You are running as a scheduled background task with no human present
- No one is available to answer questions or approve permissions
- Make reasonable decisions independently
- If a step fails, log the error clearly and continue with remaining steps
- Summarize what you accomplished and any issues encountered
- Do NOT use AskUserQuestion or any interactive features
- Current time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- Job: $($job.name) - $($job.description)
"@

    if ($job.PSObject.Properties['appendSystemPrompt'] -and $job.appendSystemPrompt) {
        $autonomyPrompt += "`n`n$($job.appendSystemPrompt)"
    }

    # 10. Build Claude CLI arguments array
    $cliArgs = @(
        '-p', $job.prompt,
        '--dangerously-skip-permissions',
        '--output-format', 'json',
        '--append-system-prompt', $autonomyPrompt,
        '--verbose'
    )

    # Optional: model
    if ($job.PSObject.Properties['model'] -and $job.model) {
        $cliArgs += '--model'
        $cliArgs += $job.model
    }

    # Optional: effort
    if ($job.PSObject.Properties['effort'] -and $job.effort) {
        $cliArgs += '--effort'
        $cliArgs += $job.effort
    }

    # Optional: max budget (only if explicitly set)
    if ($job.PSObject.Properties['maxBudgetUsd'] -and $null -ne $job.maxBudgetUsd) {
        $cliArgs += '--max-budget-usd'
        $cliArgs += $job.maxBudgetUsd.ToString()
    }

    # Optional: allowed tools
    if ($job.PSObject.Properties['allowedTools'] -and $job.allowedTools) {
        $tools = @($job.allowedTools)
        if ($tools.Count -gt 0) {
            $cliArgs += '--allowedTools'
            $cliArgs += ($tools -join ',')
        }
    }

    # Optional: disallowed tools
    if ($job.PSObject.Properties['disallowedTools'] -and $job.disallowedTools) {
        $tools = @($job.disallowedTools)
        if ($tools.Count -gt 0) {
            $cliArgs += '--disallowedTools'
            $cliArgs += ($tools -join ',')
        }
    }

    # Optional: MCP config
    if ($job.PSObject.Properties['mcpConfig'] -and $job.mcpConfig) {
        $mcpPath = Expand-TildePath $job.mcpConfig
        if (Test-Path $mcpPath) {
            $cliArgs += '--mcp-config'
            $cliArgs += $mcpPath
        } else {
            Write-Log "MCP config not found: $mcpPath. Skipping." -IsError
        }
    }

    # Optional: no session persistence
    if (-not $job.PSObject.Properties['noSessionPersistence'] -or $job.noSessionPersistence -ne $false) {
        $cliArgs += '--no-session-persistence'
    }

    Write-Log "Prompt: $($job.prompt)"
    Write-Log "Model: $(if ($job.model) { $job.model } else { 'default' })"
    if ($null -ne $job.maxBudgetUsd) { Write-Log "Budget: `$$($job.maxBudgetUsd)" }
    if ($job.PSObject.Properties['effort'] -and $job.effort) { Write-Log "Effort: $($job.effort)" }
    Write-Log "Executing Claude CLI..."
    Write-Log "---"

    # 11. Execute Claude CLI
    $startTime = Get-Date

    Push-Location $workDir
    try {
        $output = & claude @cliArgs 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $endTime = Get-Date
    $duration = ($endTime - $startTime).TotalSeconds

    # Write claude output to log
    Write-Log "---"
    Write-Log "Claude CLI output:"
    $output | Out-File -Append -FilePath $Script:LogFile -Encoding utf8

    # 12. Try to parse JSON result for summary
    try {
        $jsonResult = $output | ConvertFrom-Json -ErrorAction Stop
        if ($jsonResult.PSObject.Properties['result']) {
            Write-Log "Result preview: $($jsonResult.result.Substring(0, [Math]::Min(200, $jsonResult.result.Length)))..."
        }
        if ($jsonResult.PSObject.Properties['cost_usd']) {
            Write-Log "Cost: `$$($jsonResult.cost_usd)"
        }
    } catch {
        # Not valid JSON - that's okay, raw output was already logged
    }

    # 13. Update job status
    $job | Add-Member -NotePropertyName 'lastRunAt' -NotePropertyValue ($endTime.ToString('yyyy-MM-ddTHH:mm:ss')) -Force
    $job | Add-Member -NotePropertyName 'lastRunStatus' -NotePropertyValue $(if ($exitCode -eq 0) { 'success' } else { "failed:$exitCode" }) -Force
    $job | Add-Member -NotePropertyName 'lastRunDurationSec' -NotePropertyValue ([Math]::Round($duration, 1)) -Force

    Write-JobJson -Job $job -Path $JobFile

    Write-Log "---"
    Write-Log "Job completed: status=$($job.lastRunStatus), duration=$([Math]::Round($duration, 1))s"

    # Send notification for job failures
    if ($exitCode -ne 0) {
        Send-FailureNotification -JobName $JobName -Reason "Exit code $exitCode. Check logs for details."
    }

    exit $exitCode

} catch {
    # Fatal error handler
    Write-Log "FATAL ERROR: $_" -IsError
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -IsError
    Send-FailureNotification -JobName $JobName -Reason "Fatal error: $($_.Exception.Message)"

    # Try to update job status even on fatal error
    try {
        if (Test-Path $JobFile) {
            $job = Get-Content -Path $JobFile -Raw | ConvertFrom-Json
            $job | Add-Member -NotePropertyName 'lastRunAt' -NotePropertyValue (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') -Force
            $job | Add-Member -NotePropertyName 'lastRunStatus' -NotePropertyValue "error:$($_.Exception.Message)" -Force
            Write-JobJson -Job $job -Path $JobFile
        }
    } catch {
        Write-Log "Failed to update job status: $_" -IsError
    }

    exit 1
}
