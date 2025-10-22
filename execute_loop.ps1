<#
.SYNOPSIS
  Runs iterative AI-assisted code execution loops via Aider on Windows.

.DESCRIPTION
  Implements the iterative workflow:
    Prompt for progress → Build → Fix → Verify completion (READY/QUESTIONS).
  Uses GPT-5-mini for edits/fixes and Grok-4-Fast (or fallback) for validation.
  Provides compile gate and human-in-loop safety.

.EXAMPLE
  .\task_execution_loop.ps1 -MaxCycles 5 -TaskPrompt "Implement JWT middleware"

.EXITCODES
  0  = Completed successfully ("READY FOR TESTING")
  42 = Questions raised (requires human)
  1  = Error / Max cycles exceeded
#>

param(
    [Parameter(Mandatory = $true)]
    [int]$MaxCycles,
    [Parameter(Mandatory = $true)]
    [string]$TaskPrompt
)

# === CONFIG =====================================================
$ErrorActionPreference = 'Stop'
$LogFile = "task_loop.log"
$TempDir = Join-Path $env:TEMP ("aider_loop_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir | Out-Null

$BuildCmd       = "cargo build"
$FastCheckCmd   = "cargo check --quiet"
$MaxFixAttempts = 5
$MaxRetries     = 3

$ModelCode      = $env:MODEL_CODE      ?? "gpt-5-mini"
$ModelCheck     = $env:MODEL_CHECK     ?? "openrouter/x-ai/grok-4-fast"
$ModelFallback  = $env:MODEL_FALLBACK  ?? "anthropic/claude-3-haiku"

Start-Transcript -Path $LogFile -Append
function Timestamp { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }

Write-Host "[$(Timestamp)] Starting task loop for: $TaskPrompt (Max cycles: $MaxCycles)" -ForegroundColor Cyan

# === CLEANUP ====================================================
trap {
    if (Test-Path $TempDir) { Remove-Item -Recurse -Force $TempDir }
    Stop-Transcript | Out-Null
    exit 1
}

# === UTILITIES ==================================================

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
            Write-Warning "[$(Timestamp)] Retry attempt $attempt failed. Retrying in $($attempt * 2)s..."
            Start-Sleep -Seconds ($attempt * 2)
            $attempt++
        }
    }
}

function Run-AiderPrompt {
    param(
        [string]$Model,
        [string]$Message,
        [string]$OutputPath
    )

    Write-Host "[$(Timestamp)] Running Aider with model=$Model" -ForegroundColor Yellow
    $CommandBlock = {
        & aider --restore-chat-history `
                --yes `
                --no-auto-commits `
                --model $using:Model `
                --message $using:Message |
        Out-File -FilePath $using:OutputPath -Encoding UTF8
    }

    Invoke-WithRetry $CommandBlock
}

function Check-Build {
    param([string]$OutFile)

    try {
        & $FastCheckCmd *> $OutFile
        Write-Host "[$(Timestamp)] Cargo check passed." -ForegroundColor Green
        return $true
    } catch {
        Write-Warning "Cargo check failed; running full build..."
        try {
            & $BuildCmd *> $OutFile
            Write-Host "[$(Timestamp)] Cargo build succeeded." -ForegroundColor Green
            return $true
        } catch {
            Write-Warning "Cargo build failed."
            return $false
        }
    }
}

function Parse-CompletionStatus {
    param([string]$Text)
    if ($Text -match "(?i)ready\s+for\s+testing")  { return "ready" }
    elseif ($Text -match "(?i)questions\s+to\s+answer") { return "questions" }
    else { return "unclear" }
}

# === MAIN LOOP ==================================================

$Cycle = 0

while ($Cycle -lt $MaxCycles) {
    $Cycle++
    Write-Host "`n=== [$(Timestamp)] Cycle $Cycle / $MaxCycles ===" -ForegroundColor White

    # --- Step 1: Prompt for task progress (gpt-5-mini)
    $TaskMsg = "Continue working on this task: $TaskPrompt. " +
               "Make incremental, verified progress. Focus on clean, tested Rust code."
    $RespFile = Join-Path $TempDir "resp_$Cycle.txt"
    Run-AiderPrompt -Model $ModelCode -Message $TaskMsg -OutputPath $RespFile
    Write-Host "[$(Timestamp)] Task response recorded." -ForegroundColor Gray

    # --- Step 2: Build and Fix loop
    $BuildOut = Join-Path $TempDir "build_$Cycle.log"
    $BuildSuccess = $false
    $FixAttempts = 0

    while (-not $BuildSuccess -and $FixAttempts -lt $MaxFixAttempts) {
        if (-not (Check-Build -OutFile $BuildOut)) {
            $FixAttempts++
            $Errors = Get-Content -Path $BuildOut -Raw
            $FixMsg = @"
Fix these compile errors from cargo build. Focus on targeted corrections only.

Errors:
$Errors

Make the build pass without breaking existing functionality.
"@
            $FixResp = Join-Path $TempDir "fix_${Cycle}_${FixAttempts}.txt"
            Run-AiderPrompt -Model $ModelCode -Message $FixMsg -OutputPath $FixResp
            Write-Host "[$(Timestamp)] Fix attempt $FixAttempts submitted." -ForegroundColor DarkYellow
        } else {
            $BuildSuccess = $true
        }
    }

    if (-not $BuildSuccess) {
        Write-Error "Max fix attempts ($MaxFixAttempts) reached without successful build."
        exit 1
    }

    # --- Step 3: Completion check (Grok / fallback)
    $CheckMsg = @"
Review the latest changes for task: $TaskPrompt.
Decide if the work is ready for testing.

Respond ONLY with:
- 'READY FOR TESTING' if complete and confident
- 'QUESTIONS TO ANSWER: [1. ..., 2. ...]' if uncertainties remain
No additional commentary.
"@
    $CheckRespFile = Join-Path $TempDir "check_$Cycle.txt"

    try {
        Run-AiderPrompt -Model $ModelCheck -Message $CheckMsg -OutputPath $CheckRespFile
    } catch {
        Write-Warning "Primary validation model failed; retrying with fallback $ModelFallback."
        Run-AiderPrompt -Model $ModelFallback -Message $CheckMsg -OutputPath $CheckRespFile
    }

    $CheckResp = Get-Content -Path $CheckRespFile -Raw
    $Result = Parse-CompletionStatus -Text $CheckResp

    switch ($Result) {
        "ready" {
            Write-Host "[$(Timestamp)] ✅ Task complete — ready for testing!" -ForegroundColor Green
            exit 0
        }
        "questions" {
            Write-Host "[$(Timestamp)] ❓ Questions raised. Output:" -ForegroundColor Yellow
            Write-Host $CheckResp
            exit 42
        }
        default {
            Write-Host "[$(Timestamp)] Not ready — continuing to next cycle." -ForegroundColor Gray
        }
    }
}

Write-Warning "[$(Timestamp)] Max cycles ($MaxCycles) reached without completion."
Stop-Transcript | Out-Null
exit 1