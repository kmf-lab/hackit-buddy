#!/bin/bash
# build_fresh_history.sh
# -------------------------------------------------------------
# Creates a fresh Aider chat history seeded with a project plan
# and relevant files. The model only performs a confidence review
# using Grok‑4‑fast (or fallback model), no code edits.
# -------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

LOG_FILE="aider_setup.log"
TEMP_DIR=$(mktemp -d /tmp/aider_setup.XXXXXX)
MODEL_PRIMARY=${MODEL_PRIMARY:-"openrouter/x-ai/grok-4-fast"}
MODEL_FALLBACK=${MODEL_FALLBACK:-"anthropic/claude-3-haiku"}

cleanup() {
  rm -rf "$TEMP_DIR"
  echo "[$(date -Iseconds)] Cleanup complete."
}
trap cleanup EXIT

exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date -Iseconds)] Starting build_fresh_history.sh"

# === Arguments & validation =======================================
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <plan_file> <files_list> [output_history]" >&2
  exit 1
fi

PLAN_FILE="$1"
FILES_LIST="$2"
OUTPUT_HISTORY="${3:-fresh_plan_history.md}"

[[ -f "$PLAN_FILE" ]] || { echo "Error: plan file '$PLAN_FILE' missing." >&2; exit 1; }
[[ -f "$FILES_LIST" ]] || { echo "Error: files list '$FILES_LIST' missing." >&2; exit 1; }

# === Helper utilities ============================================

timestamp() { date +"[%Y-%m-%d %H:%M:%S]"; }

run_with_retry() {
  # Usage: run_with_retry <command...>
  local attempt=1
  local max_attempts=3
  until "$@"; do
    if ((attempt >= max_attempts)); then
      echo "$(timestamp) ❌ Command failed after $max_attempts attempts: $*" >&2
      return 1
    fi
    echo "$(timestamp) Retry attempt $((attempt++))..."
    sleep $((attempt * 2))
  done
}

# === Prepare plan + file list ====================================

PLAN_CONTENT=$(<"$PLAN_FILE")

# Normalize file list (comma or newline separated)
if [[ $(wc -l <"$FILES_LIST") -gt 1 ]]; then
  FILES=$(tr '\n,' '  ' <"$FILES_LIST" | xargs)
else
  FILES=$(tr ',' ' ' <"$FILES_LIST" | xargs)
fi

echo "$(timestamp) Plan file: $PLAN_FILE"
echo "$(timestamp) Files to include: $FILES"
echo "$(timestamp) Output history: $OUTPUT_HISTORY"
echo "Plan preview (first 200 chars): ${PLAN_CONTENT:0:200}..."

# === Construct initial message ===================================

FULL_MESSAGE="You are starting a new Aider session for a Rust project.
The following files are provided for context: $FILES

Full project plan:
$PLAN_CONTENT

Your only task: Review this plan for understanding.
Do NOT make code edits. Respond exactly as one of:
- 'CONFIDENT: Plan is fully clear and ready to proceed.'
- 'QUESTIONS: [1. ..., 2. ..., 3. ...]' if any ambiguities remain.
Keep answers concise and structured."

# === Run aider to initialize history =============================

echo "$(timestamp) Launching Aider with model: $MODEL_PRIMARY"

run_with_retry aider \
  --chat-history-file "$OUTPUT_HISTORY" \
  --restore-chat-history false \
  --model "$MODEL_PRIMARY" \
  --yes \
  --no-auto-commits \
  --message "$FULL_MESSAGE" \
  $FILES ||
{
  echo "$(timestamp) Primary model failed. Retrying with fallback: $MODEL_FALLBACK"
  run_with_retry aider \
    --chat-history-file "$OUTPUT_HISTORY" \
    --restore-chat-history false \
    --model "$MODEL_FALLBACK" \
    --yes \
    --no-auto-commits \
    --message "$FULL_MESSAGE" \
    $FILES || {
      echo "$(timestamp) All models failed. Aborting." >&2
      exit 1
    }
}

echo "$(timestamp) Fresh history created at: $OUTPUT_HISTORY"

# === Inspect history =============================================

if [[ -s "$OUTPUT_HISTORY" ]]; then
  echo ""
  echo "=== History Preview ==="
  head -n 80 "$OUTPUT_HISTORY"
fi

# === Confidence parsing ==========================================

if grep -qi "CONFIDENT" "$OUTPUT_HISTORY"; then
  echo "$(timestamp) ✅ Status: Plan confirmed 100% confident."
  EXIT_CODE=0
elif grep -qi "QUESTIONS" "$OUTPUT_HISTORY"; then
  echo "$(timestamp) ❓ Status: Questions raised — revise plan and re-run."
  EXIT_CODE=42
else
  echo "$(timestamp) ⚠️  Status: Unexpected response — manual review required."
  EXIT_CODE=1
fi

echo ""
echo "To resume development:"
echo "aider --restore-chat-history --chat-history-file $OUTPUT_HISTORY --model gpt-5-mini"
exit "$EXIT_CODE"