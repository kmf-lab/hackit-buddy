#!/bin/bash
# task_execution_loop.sh
# -------------------------------------------------------------------
# Automates iterative AI-assisted coding with Aider, using OpenRouter.
# Workflow: prompt for progress → build/check/fix → verify completion.
# Enforces compile loop correctness, human-in-loop intervention for
# ambiguity, and model cost efficiency.
# -------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# === CONFIGURATION ================================================

LOG_FILE="task_loop.log"
BUILD_CMD="cargo build"
FAST_CHECK_CMD="cargo check --quiet"
TEMP_DIR=$(mktemp -d /tmp/aider_loop.XXXXXX)
MAX_FIXES=5
MAX_RETRIES=3

# Default models (environment override supported)
MODEL_CODE=${MODEL_CODE:-"gpt-5-mini"}
MODEL_CHECK=${MODEL_CHECK:-"openrouter/x-ai/grok-4-fast"}
ALT_MODEL_CHECK=${ALT_MODEL_CHECK:-"anthropic/claude-3-haiku"}

# === INPUTS =======================================================

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <max_cycles> <task_prompt>" >&2
  exit 1
fi

MAX_CYCLES=$1
TASK_PROMPT=$2

exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date -Iseconds)] Starting task loop for: $TASK_PROMPT (Max cycles: $MAX_CYCLES)"

# === VALIDATIONS ==================================================

if ! command -v aider >/dev/null; then
  echo "Error: aider is not installed. Run 'pip install aider-chat'." >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Warning: Not in a git repository. Aider context tracking may degrade." >&2
fi

# === CLEANUP HANDLER =============================================

cleanup() {
  rm -rf "$TEMP_DIR"
  echo "[$(date -Iseconds)] Cleanup complete. Exiting."
}
trap cleanup EXIT

# === UTILITIES ====================================================

timestamp() { date +"[%Y-%m-%d %H:%M:%S]"; }

run_with_retry() {
  # Usage: run_with_retry <command...>
  local attempt=1
  until "$@"; do
    if ((attempt >= MAX_RETRIES)); then
      echo "$(timestamp) Exceeded max retries for: $*" >&2
      return 1
    fi
    echo "$(timestamp) Retry $((attempt++)) after failure..."
    sleep $((attempt * 2))
  done
}

# === AIDER INTERFACE ==============================================

run_aider_prompt() {
  local model="$1" message="$2" outfile="$3"
  local expect_log="$TEMP_DIR/aider_expect.log"

  expect <<EOF
    log_file -a "$expect_log"
    set timeout 300
    spawn aider --model "$model" --restore-chat-history --yes --no-auto-commits
    expect {
      "aider:" {
        send "$message\r"
        expect {
          "aider:" { exp_continue }
          eof {}
        }
      }
      timeout { puts "Timeout waiting for aider response: $message" }
    }
    expect eof
EOF

  # Extract latest AI response
  awk '/### Assistant/,/aider:/' "$expect_log" | sed '/aider:/d' >"$outfile"
}

# === BUILD VALIDATION =============================================

check_build() {
  local output_file="$1"
  if run_with_retry $FAST_CHECK_CMD >"$output_file" 2>&1; then
    echo "$(timestamp) Cargo syntax check passed."
    return 0
  fi
  echo "$(timestamp) cargo check failed; running full build..."
  $BUILD_CMD >"$output_file" 2>&1 || return 1
  echo "$(timestamp) Cargo build succeeded."
}

# === RESPONSE PARSING =============================================

parse_completion_status() {
  local text="$1"
  if grep -qi "ready for testing" <<<"$text"; then
    echo "ready"
  elif grep -qi "questions to answer" <<<"$text"; then
    echo "questions"
  else
    echo "unclear"
  fi
}

# === MAIN LOOP ====================================================

CYCLE=0

while ((CYCLE < MAX_CYCLES)); do
  ((CYCLE++))
  echo ""
  echo "=== [$(date -Iseconds)] Cycle $CYCLE / $MAX_CYCLES ==="

  # Step 1: coding progress ----------------------------------------
  TASK_MSG="Continue working on this task: $TASK_PROMPT.
Make incremental, logically consistent progress per the plan.
Focus on clean, tested Rust code. Avoid disruptive refactors."
  TASK_RESP_FILE=$(mktemp "$TEMP_DIR/resp.XXXX")

  run_aider_prompt "$MODEL_CODE" "$TASK_MSG" "$TASK_RESP_FILE"
  echo "$(timestamp) Task response received."

  # Step 2: compile + fix loop -------------------------------------
  BUILD_OUTPUT=$(mktemp "$TEMP_DIR/build.XXXX")
  FIX_ATTEMPT=0
  BUILD_OK=false

  until $BUILD_OK || ((FIX_ATTEMPT >= MAX_FIXES)); do
    if ! check_build "$BUILD_OUTPUT"; then
      ((FIX_ATTEMPT++))
      FIX_MSG="Fix the following compile errors from cargo build.
Apply *targeted* patches only — no unrelated edits.
Errors:
$(<"$BUILD_OUTPUT")
Ensure build passes fully."
      FIX_RESP_FILE=$(mktemp "$TEMP_DIR/fix.XXXX")
      run_aider_prompt "$MODEL_CODE" "$FIX_MSG" "$FIX_RESP_FILE"
      echo "$(timestamp) Fix attempt $FIX_ATTEMPT response logged."
    else
      BUILD_OK=true
    fi
  done

  if ! $BUILD_OK; then
    echo "$(timestamp) Max fix attempts ($MAX_FIXES) reached. Halting iteration." >&2
    exit 1
  fi

  # Step 3: completion validation ----------------------------------
  CHECK_MSG="Review the recent changes related to: $TASK_PROMPT.
Decide and reply with ONE of:
- 'READY FOR TESTING'
- 'QUESTIONS TO ANSWER: [list 1-3 brief questions]'
No other text."
  CHECK_RESP_FILE=$(mktemp "$TEMP_DIR/check.XXXX")

  if ! run_aider_prompt "$MODEL_CHECK" "$CHECK_MSG" "$CHECK_RESP_FILE"; then
    echo "$(timestamp) Validation model failed; trying fallback $ALT_MODEL_CHECK"
    run_aider_prompt "$ALT_MODEL_CHECK" "$CHECK_MSG" "$CHECK_RESP_FILE" || {
      echo "$(timestamp) All validation models failed — aborting." >&2
      exit 1
    }
  fi

  CHECK_RESPONSE=$(<"$CHECK_RESP_FILE")
  COMPLETION_STATE=$(parse_completion_status "$CHECK_RESPONSE")

  case $COMPLETION_STATE in
  ready)
    echo "$(timestamp) ✅ Task complete and ready for testing."
    exit 0
    ;;
  questions)
    echo "$(timestamp) ❓ Model raised questions:"
    echo "$CHECK_RESPONSE" | grep -E "^[0-9]|QUESTIONS|ANSWER" || echo "$CHECK_RESPONSE"
    echo "$(timestamp) Exiting for human resolution."
    exit 42
    ;;
  *)
    echo "$(timestamp) Not ready — continuing to next cycle."
    ;;
  esac

done

echo "$(timestamp) ⚠️ Max cycles ($MAX_CYCLES) reached without completion."
exit 1