# Chrome Extension Automation: What We Tried and Why We Stopped

This document preserves everything we learned while attempting to schedule Chrome extension jobs with Claude Scheduler. The goal was to let Claude browse the web using your logged-in browser sessions on a schedule — checking dashboards, reading emails, monitoring Jira boards, etc. — all unattended.

**Bottom line**: The Claude Chrome extension's MCP connection is fundamentally unreliable for unattended automation. The upstream issue is tracked at [anthropics/claude-code#26347](https://github.com/anthropics/claude-code/issues/26347). We'll revisit when it stabilizes.

---

## What We Set Out To Do

Schedule Claude Code CLI jobs that could use the Chrome extension to:
- Read and summarize Gmail threads
- Check Jira dashboards and create reports
- Browse the user's X/Twitter feed for analysis
- Access any logged-in web service the user has open in Chrome

The key advantage over tools like Playwright: **no separate authentication**. The Chrome extension piggybacks on the user's existing browser sessions — cookies, OAuth tokens, and all.

## The Architecture We Built

### Job-level Chrome flag

Added a `-RequiresChrome` switch to `create`. Jobs with this flag got:
- A `requiresChrome: true` field in their JSON definition
- Pre-flight checks before execution (browser running? extension connected? pipe reachable?)
- A Chrome-specific autonomy system prompt with instructions about tab management
- Post-execution output scanning to detect silent Chrome failures

### Runner enhancements

The runner (`runner.ps1`) was extended with:
- `Test-ChromePrereqs` function: validated browser process, named pipe, native host manifest
- Chrome autonomy prompt injection via `--append-system-prompt`
- Output pattern matching: scanned for `tabs_context_mcp`, `navigate`, etc. to verify Chrome tools were actually used
- Chrome-specific failure status: `failed:chrome-disconnected` when tools weren't invoked despite `requiresChrome: true`

### Management CLI additions

- `setup-chrome` command: automated all Chrome prerequisites in one step
- Auto-setup on first Chrome job: if user ran `create -RequiresChrome`, it would trigger `setup-chrome` automatically
- `restart-browser` command: killed stale `chrome-native-host.exe` processes and prompted browser restart

---

## Problem 1: Service Worker Idle Timeout

**What**: Chrome's Manifest V3 kills extension service workers after ~5 minutes of inactivity. The Claude extension communicates via a named pipe (`\\.\pipe\claude-mcp-browser-bridge-USERNAME`), and when the service worker dies, the pipe disappears.

**Impact**: Any scheduled job running more than 5 minutes after the last browser interaction would find the extension dead.

**Our fix**: Created `chrome-ping.ps1` — a lightweight script that pinged the named pipe every 4 minutes via Task Scheduler. The ping was a minimal JSON-RPC message (`{"jsonrpc":"2.0","method":"ping","id":1}`) sent to `\\.\pipe\claude-mcp-browser-bridge-USERNAME`.

```powershell
# Registered as a Task Scheduler job running every 4 minutes
$pipePath = "\\.\pipe\claude-mcp-browser-bridge-$env:USERNAME"
$pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, 'InOut')
$pipe.Connect(3000)
# Send minimal JSON-RPC ping
$writer.Write('{"jsonrpc":"2.0","method":"ping","id":1}')
```

**Result**: This worked — the pipe stayed alive and the service worker remained active. But it introduced Problem 4 below (window flash) and was fighting a symptom rather than the root cause.

---

## Problem 2: Competing Native Messaging Host

**What**: Claude Desktop installs a native messaging host manifest at:
```
%APPDATA%\Claude\ChromeNativeHost\com.anthropic.claude_browser_extension.json
```

Chrome's native messaging system routes ALL extension messages to whichever host registered first. When Claude Desktop's manifest exists, it intercepts the extension connection even when Desktop isn't running.

**Impact**: Claude Code CLI couldn't connect to the Chrome extension at all. The extension appeared "connected" in the browser but messages went nowhere.

**Our fix**: `setup-chrome` auto-detected the competing host and renamed it:
```powershell
$desktopHost = "$env:APPDATA\Claude\ChromeNativeHost\com.anthropic.claude_browser_extension.json"
if (Test-Path $desktopHost) {
    Rename-Item $desktopHost -NewName "com.anthropic.claude_browser_extension.json.disabled"
}
```

We also verified the Claude Code native host existed at:
```
%APPDATA%\Claude Code\ChromeNativeHost\com.anthropic.claude_code_browser_extension.json
```

**Result**: This fixed the routing issue. We tracked whether the rename was done (`$chromeDisabledDesktopHost` flag) and showed a prominent warning explaining what happened and why.

---

## Problem 3: Window Flash (Console Host Flicker)

**What**: Windows Task Scheduler creates a console host window *before* PowerShell can execute `[Console]::WindowPosition` or `-WindowStyle Hidden`. This caused a visible window flash every 4 minutes when `chrome-ping.ps1` ran.

**Impact**: Annoying visual disruption every 4 minutes while working.

**Our fix**: Created a VBScript wrapper (`chrome-ping-launcher.vbs`):
```vbscript
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """", 0, True
```

The `0` in `WshShell.Run(..., 0, True)` means "run hidden from the start". VBScript's `wscript.exe` doesn't create a console window, so the flash was eliminated.

Task Scheduler was then registered to run `wscript.exe` with the VBS file as argument instead of `powershell.exe` directly.

**Result**: Completely eliminated the window flash.

---

## Problem 4: Silent Chrome Failures

**What**: Claude CLI exits with code 0 even when the Chrome extension completely fails. It reports the failure conversationally in its JSON output — something like "I wasn't able to connect to the browser extension" — but the exit code says "success".

**Impact**: Job status showed `success` but nothing was actually browsed.

**Our fix**: Post-execution output scanning in `runner.ps1`:
```powershell
$chromeToolPatterns = @('tabs_context_mcp', 'navigate', 'read_page', 'find', 'computer', 'form_input')
$usedChromeTools = $false
foreach ($pattern in $chromeToolPatterns) {
    if ($output -match $pattern) { $usedChromeTools = $true; break }
}
if ($job.requiresChrome -and -not $usedChromeTools) {
    # Mark as failed:chrome-disconnected
}
```

We also added retry logic: if Chrome tools weren't detected, the runner would kill stale `chrome-native-host.exe` processes, wait, and retry once.

**Result**: Better failure detection, but the retry was unreliable since the root cause (Problem 5 below) was a platform-level issue.

---

## Problem 5: The UTF-8 BOM Discovery

**What**: PowerShell 5.1's `[System.Management.Automation.Language.Parser]::ParseFile()` method misparses expandable here-strings (`@"..."@`) when the source file is encoded as UTF-8 without BOM.

**Symptoms**: Parse errors like "Missing statement body in while loop" at seemingly correct code, but only when run via Task Scheduler (which uses `ParseFile` internally). Running the same script interactively via `powershell -File` worked fine because that path uses `ParseInput` (string-based parsing).

**Debugging journey**:
1. Verified brace balance was perfect (manually traced opening/closing through 400+ lines)
2. Tested CRLF vs LF — not the issue
3. Discovered `ParseFile` fails but `ParseInput` succeeds on identical content
4. Tested all encoding combinations:
   - UTF-8 with BOM: ✅ parses correctly
   - UTF-8 without BOM: ❌ parse errors
   - Windows-1252: ✅ parses correctly

**Root cause**: PowerShell 5.1's file-based parser assumes Windows-1252 encoding when no BOM is present. The expandable here-string syntax (`@"` followed by a newline) gets misinterpreted because certain byte sequences in the autonomy prompt (which contained long multi-line strings) are parsed differently under Windows-1252 vs UTF-8.

**Fix**: Add UTF-8 BOM (bytes `EF BB BF`) to the beginning of all `.ps1` files.

**Lesson**: This was particularly insidious because it only manifested in files with expandable here-strings containing certain characters, and only when loaded via `ParseFile` (not `ParseInput`). Interactive execution always worked.

---

## Problem 6: The Platform-Level Killer

**What**: [GitHub issue #26347](https://github.com/anthropics/claude-code/issues/26347) — The Chrome extension's MCP process becomes stale mid-session. When Claude Code tries to reconnect, it kills the MCP process, which permanently deregisters all Chrome tools for the remainder of the CLI session. There is no recovery short of restarting the entire Claude CLI process.

**Impact**: Even with perfect keepalive pinging, the extension would randomly disconnect during long-running jobs. Once disconnected, no amount of retry logic could recover — the tools were simply gone from Claude's perspective.

**Why our fixes couldn't help**: All our mitigations (keepalive ping, competing host detection, retry logic, output scanning) addressed the *symptoms* of extension instability. This issue is in the Claude Code CLI's MCP client itself — when it detects a stale MCP connection and tries to reconnect, it kills the process in a way that deregisters tools permanently. This is an upstream bug in Claude Code, not something we can work around from the scheduling layer.

**Others affected**: The GitHub issue has multiple reports of the same behavior. It's a known issue with no fix timeline as of February 2026.

---

## What Would Need to Change

For Chrome extension automation to be viable for unattended scheduling, we'd need:

1. **Stable MCP reconnection**: Claude Code's CLI must be able to reconnect to the Chrome extension MCP without permanently losing tool registrations. This is the #1 blocker.

2. **Service worker lifecycle management**: Chrome's Manifest V3 service worker idle timeout needs a robust keep-alive mechanism built into the extension itself, not requiring external pinging.

3. **Proper error signaling**: Claude CLI should exit non-zero when Chrome extension tools fail, rather than reporting failure conversationally with exit code 0.

4. **Alternative approach**: A non-extension approach using direct Chrome DevTools Protocol (CDP) or Playwright with persistent browser contexts might be more reliable than the extension-based MCP bridge.

---

## Files We Created (Now Removed)

| File | Purpose |
|------|---------|
| `chrome-ping.ps1` | Pinged the named pipe every 4 minutes to keep the extension service worker alive |
| `chrome-ping-launcher.vbs` | VBScript wrapper to run the ping script without console window flash |
| `examples/` directory | Example job JSONs including Chrome jobs |

### Functions we added to existing files (now reverted)

| File | Function/Section |
|------|------------------|
| `runner.ps1` | `Test-ChromePrereqs` — validated browser, pipe, native host before Chrome jobs |
| `runner.ps1` | Chrome output scanning and retry logic |
| `runner.ps1` | Chrome-specific autonomy prompt with tab management instructions |
| `claude-scheduler.ps1` | `-RequiresChrome` parameter and `requiresChrome` JSON field |
| `claude-scheduler.ps1` | `setup-chrome` command (~150 lines) |
| `claude-scheduler.ps1` | `restart-browser` command |
| `claude-scheduler.ps1` | Auto-setup trigger on first Chrome job creation |
| `install.ps1` | Copying `chrome-ping.ps1` and `chrome-ping-launcher.vbs` |

---

## Timeline

1. **Core scheduler built** — 4-commit foundation: create/list/enable/disable/run/delete/logs/status/purge-logs with Task Scheduler integration, runner with autonomous prompt injection, installer, skill.

2. **Chrome extension support added** — `-RequiresChrome` flag, `setup-chrome` command, pre-flight checks, Chrome autonomy prompt, tab cleanup instructions.

3. **Service worker keepalive** — `chrome-ping.ps1` with 4-minute Task Scheduler interval, named pipe ping, logging.

4. **Competing host detection** — Auto-detect and disable Claude Desktop's native messaging host manifest.

5. **Window flash fix** — VBScript wrapper (`chrome-ping-launcher.vbs`) for hidden execution.

6. **Silent failure detection** — Output scanning for Chrome tool usage patterns, retry-once logic.

7. **Phone notifications** — WhatsApp/ntfy/Discord alerts on job failure (kept — works for all jobs, not Chrome-specific).

8. **UTF-8 BOM discovery** — PowerShell 5.1 `ParseFile` vs `ParseInput` encoding bug. Fixed by adding BOM to all script files.

9. **Platform-level issue discovered** — Found GitHub issue #26347 confirming the MCP disconnect is an upstream Claude Code bug. Decision to revert all Chrome work and wait for a fix.

---

## Preserving the Knowledge

All the Chrome implementation code is preserved in the git stash (`git stash list` to see it). If the upstream issue is resolved and you want to resurrect Chrome support:

```powershell
git stash list          # Find the stash with Chrome changes
git stash show -p       # Review the full diff
git stash apply         # Apply to working tree (doesn't delete the stash)
```

The stash contains the complete working Chrome implementation (minus the platform-level reliability issue that we can't fix).
