<#
.SYNOPSIS
  Initializes a fresh Aider chat history by injecting a project plan and files.

.DESCRIPTION
  Launches Aider to review a detailed plan using Grok-4-fast (or fallback model) for confidence checking,
  without performing edits or commits. Saves the conversation history for resumption with future commands.

.EXAMPLE
  .\build_fresh_history.ps1 -PlanFile "plan.txt" -FilesList "files.txt"
  .\build_fresh_history.ps1 -RepoPath "C:\Repos\myproj" -PlanFile "plan.txt" -FilesList "files.txt" -OutputHistory "init_history.md"

.EXITCODES
  0  - Plan confirmed confident
  42 - Questions raised
  1  - Failure or unexpected response
#>

param(
    [string]$RepoPath = (Get-Location).Path,
    [Parameter(Mandatory = $true)]
    [string]$PlanFile,
    [Parameter(Mandatory = $true)]
    [string]$FilesList,
    [string]$OutputHistory = "fresh_plan_history.md"
)

# region --- CONFIG & INITIALIZATION ---------------------------------------------

$ErrorActionPreference = 'Stop'
$LogFile = "aider_setup.log"
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("aider_setup_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir | Out-Null

# Default model choices (override via env vars if desired)
$env:MODEL_PRIMARY = $env:MODEL_PRIMARY       ?? "openrouter/x-ai/grok-4-fast"
$env:MODEL_FALLBACK = $env:MODEL_FALLBACK     ?? "anthropic/claude-3-haiku"

function Timestamp { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }

Start-Transcript -Path $LogFile -Append
Write-Host "[$(Timestamp)] Starting build_fresh_history.ps1" -ForegroundColor Cyan

# endregion

try {
    # --- Change to repo --------------------------------------------------------
    Set-Location -Path $RepoPath

    if (-not (Test-Path .git)) {
        Write-Warning "Not in a Git repo. Aider works best in repos."
    }

    # --- File validation ------------------------------------------------------
    $fullPlan = Join-Path $RepoPath $PlanFile
    $fullList = Join-Path $RepoPath $FilesList
    $fullOut  = Join-Path $RepoPath $OutputHistory

    if (-not (Test-Path $fullPlan))  { throw "Plan file '$fullPlan' not found." }
    if (-not (Test-Path $fullList))  { throw "Files list '$fullList' not found." }

    Write-Host "Repository : $RepoPath"
    Write-Host "Plan file  : $PlanFile"
    Write-Host "Files list : $FilesList"
    Write-Host "Output file: $OutputHistory"
    Write-Host ""

    # --- Read files -----------------------------------------------------------
    $PlanContent = Get-Content -Path $fullPlan -Raw
    $ListRaw = Get-Content -Path $fullList -Raw
    if ($ListRaw -match "[`r`n]+") {
        $Files = ($ListRaw -split "[`r`n]+" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() -replace ',', ' ' }) -join ' '
    } else {
        $Files = ($ListRaw -replace ',', ' ').Trim()
    }

    Write-Host "Plan preview (first 200 chars): $($PlanContent.Substring(0, [Math]::Min(200, $PlanContent.Length)))..." -ForegroundColor Gray

    # --- Build the message ----------------------------------------------------
    $FullMessage = @"
You are starting a new session with this detailed project plan. The key files are already added to the context: $Files

Full plan:
$PlanContent

IMPORTANT:
Do NOT begin any implementation or edits yet.
Your sole task is to review the plan and confirm full understanding.

Respond ONLY with ONE of:
- CONFIDENT: Plan is fully clear and ready to proceed.
- QUESTIONS: [1. question, 2. question, 3. question]

Be concise, structured, and avoid any code or commentary.
"@

    # region --- Helper: retry logic -------------------------------------------
    function Invoke-WithRetry {
        param([ScriptBlock]$Command, [int]$MaxAttempts = 3)
        $attempt = 1
        while ($true) {
            try {
                & $Command
                return
            } catch {
                if ($attempt -ge $MaxAttempts) {
                    throw "Command failed after $MaxAttempts attempts: $($_.Exception.Message)"
                }
                Write-Warning "Retry attempt $attempt failed. Retrying in $($attempt * 2)s..."
                Start-Sleep -Seconds ($attempt * 2)
                $attempt++
            }
        }
    }
    # endregion

    # --- Run Aider primary model ----------------------------------------------
    Write-Host "[$(Timestamp)] Launching Aider with model $env:MODEL_PRIMARY" -ForegroundColor Yellow

    $CommandBlockPrimary = {
        & aider `
            --chat-history-file $fullOut `
            --restore-chat-history false `
            --model $env:MODEL_PRIMARY `
            --yes `
            --no-auto-commits `
            --message $FullMessage `
            $Files
    }

    try {
        Invoke-WithRetry $CommandBlockPrimary
    } catch {
        Write-Warning "Primary model failed. Falling back to $env:MODEL_FALLBACK"
        $CommandBlockFallback = {
            & aider `
                --chat-history-file $fullOut `
                --restore-chat-history false `
                --model $env:MODEL_FALLBACK `
                --yes `
                --no-auto-commits `
                --message $FullMessage `
                $Files
        }
        Invoke-WithRetry $CommandBlockFallback
    }

    Write-Host "[$(Timestamp)] History created at: $fullOut" -ForegroundColor Green
    Write-Host ""

    # --- Analyze response -----------------------------------------------------
    Write-Host "=== History Preview (top 80 lines) ==="
    Get-Content -Path $fullOut -TotalCount 80 | ForEach-Object { Write-Host $_ }
    Write-Host ""

    $ExitCode = 1
    if (Select-String -Path $fullOut -Pattern "CONFIDENT" -Quiet) {
        Write-Host "[$(Timestamp)] ✅ Plan confirmed 100% confident."
        $ExitCode = 0
    } elseif (Select-String -Path $fullOut -Pattern "QUESTIONS" -Quiet) {
        Write-Host "[$(Timestamp)] ❓ Questions raised — revise plan and re-run."
        $ExitCode = 42
    } else {
        Write-Host "[$(Timestamp)] ⚠️ Unexpected response — manual review required."
        $ExitCode = 1
    }

    Write-Host ""
    Write-Host "To resume work:"
    Write-Host "  cd '$RepoPath'"
    Write-Host "  aider --restore-chat-history --chat-history-file $OutputHistory --model gpt-5-mini"
    Write-Host ""

    exit $ExitCode
}
catch {
    Write-Error "[$(Timestamp)] ❌ Error: $($_.Exception.Message)"
    exit 1
}
finally {
    if (Test-Path $TempDir) { Remove-Item -Recurse -Force $TempDir }
    Stop-Transcript | Out-Null
    Write-Host "[$(Timestamp)] Cleanup complete." -ForegroundColor Gray
}