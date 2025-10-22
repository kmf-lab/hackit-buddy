# AI-Assisted Development Automation with Aider, hackit-buddy

[![Bash](https://img.shields.io/badge/Script-Bash-blue.svg)](https://www.gnu.org/software/bash/)
[![Aider](https://img.shields.io/badge/Tool-Aider-orange.svg)](https://aider.chat/)

## Overview

This project provides a pair of Bash scripts to automate iterative, AI-assisted software development using [Aider](https://aider.chat/), an open-source terminal-based AI pair programming tool. The scripts are designed specifically for Rust projects (leveraging `cargo build` for validation) but can be adapted for other languages/build systems.

### What We're Building
- **`build_fresh_history.sh`**: Initializes a "fresh" Aider chat history by injecting a detailed project plan (e.g., 6K tokens of step-by-step instructions) and key files into the context. It uses Grok-4-fast (via OpenRouter) to perform a confidence check: The AI reviews the plan without making changes and either confirms 100% understanding or raises targeted questions for human clarification.
- **`execute_loop.sh`**: Executes a specific task (e.g., "Implement user authentication") in an iterative loop. It restores the history, prompts the AI (using GPT-5-mini for coding depth), runs `cargo build` checks with error feedback loops, and gates progress with a completion review (using Grok-4-fast for quick validation). The loop runs up to a configurable number of cycles, exiting early for success, max retries, or human-needed questions.

These scripts form a **human-in-the-loop workflow**:
1. **Plan & Validate**: Build history to ensure the AI has a clear, unambiguous roadmap.
2. **Execute Iteratively**: Break implementation into short, guarded sprints with compile-time safety nets.
3. **Intervene & Resume**: Pause on ambiguities, answer questions, and re-run to maintain momentum.

The result is a semi-automated "AI dev agent" that handles 70-80% of routine coding/fixing while keeping humans in control for creativity and edge cases.

### Why We're Doing This
Traditional development cycles (prompt → edit → test → debug) are manual and error-prone, especially in complex repos where context loss leads to hallucinations or regressions. LLMs like GPT-5-mini and Grok-4-fast excel at targeted tasks (e.g., fixing compile errors) but struggle with long-term coherence without structured scaffolding.

**Goals**:
- **Efficiency**: Automate repetitive loops (e.g., build-fix cycles) to save 2-4 hours per feature, per industry benchmarks on AI pair programming.
- **Reliability**: Enforce compile checks and confidence gates to reduce broken code by 50%+ compared to free-form prompting.
- **Scalability**: Modular for multi-step plans (e.g., run the loop per plan phase) and cross-repo use (central scripts, local plans).
- **Transparency**: Full logging, structured prompts, and exit codes for debugging/resumption—crucial for team handoffs.
- **Cost-Effective**: Tier models (cheap/fast for checks, deep for code) and cap history tokens to fit 400K windows without waste.

This setup draws from patterns in tools like GitHub Copilot Workspace and Devin AI, adapted for terminal/Aider fans. It's ideal for solo devs or small teams tackling iterative tasks like refactoring, feature adds, or bug hunts in Rust crates.

## Prerequisites

- **OS**: Linux/macOS (Bash 4+); Windows via WSL or Git Bash.
- **Tools**:
    - [Aider](https://aider.chat/docs/install.html) (install via `pip install aider-chat`).
    - [Expect](https://linux.die.net/man/1/expect) for interactive Aider sessions (`apt install expect` on Debian/Ubuntu, `brew install expect` on macOS).
    - [Cargo](https://doc.rust-lang.org/cargo/getting-started/installation.html) (for Rust build checks; adapt `BUILD_CMD` for other langs).
    - [Git](https://git-scm.com/) (Aider uses repos for context/commits).
- **API Access**:
    - OpenRouter account with API key (set as env: `export OPENROUTER_API_KEY=your_key`).
    - Models: `openrouter/x-ai/grok-4-fast` (for checks) and `gpt-5-mini` (for coding; ensure quota).
- **Aider Config** (optional but recommended): Create `.aider.conf.yml` in your repo or `~/.aider/`:
  ```yaml
  max_chat_history_tokens: 100000  # For 400K window; auto-summarizes old turns
  auto-commits: false  # Disable during loops; manual git after
  git-commit-message-file: commit_message.txt  # For custom messages
  ```
- **Project Structure**: Run scripts from a Git repo root. Prepare:
    - `plan.txt`: Detailed Markdown/text plan (e.g., "Step 1: Add auth middleware...").
    - `files_list.txt`: Repo-relative paths (one per line or comma-separated, e.g., `src/main.rs,Cargo.toml`).

## Setup

1. **Clone/Download Scripts**:
    - Save `build_fresh_history.sh` and `task_execution_loop.sh` to `~/bin/` (or a tools dir).
    - Make executable: `chmod +x ~/bin/build_fresh_history.sh ~/bin/task_execution_loop.sh`.
    - Add to PATH: `export PATH="$HOME/bin:$PATH"` in `~/.bashrc`.

2. **Test Environment**:
    - In a test repo: `git init test-repo && cd test-repo`.
    - Create dummy `plan.txt` and `files_list.txt`.
    - Run: `./build_fresh_history.sh plan.txt files_list.txt`.
    - Check `aider_setup.log` and output MD for history.

3. **Model Verification**:
    - Run `aider --model openrouter/x-ai/grok-4-fast --message "Test"` to confirm access.

## Usage

### 1. Building Fresh History (`build_fresh_history.sh`)
**Purpose**: Seed Aider with your plan for a clean, confident start. No code changes—pure validation.

**Command**:
```bash
./build_fresh_history.sh <plan_file> <files_list> [output_history.md]
```
- **Args**:
    - `<plan_file>`: Path to your instructions (e.g., `plan.txt`).
    - `<files_list>`: Paths to add to context (e.g., `files.txt` with `src/lib.rs\nCargo.toml`).
    - `[output_history]`: Defaults to `fresh_plan_history.md`.

**Example**:
```bash
cd my-rust-repo
echo "Step 1: Implement JWT auth in src/auth.rs" > plan.txt
echo "src/auth.rs\nCargo.toml" > files.txt
./build_fresh_history.sh plan.txt files.txt
```

**Output**:
- `fresh_plan_history.md`: Formatted chat (Human prompt + AI response).
- Logs to `aider_setup.log`.
- Status: "CONFIDENT" or "QUESTIONS: 1. Clarify X? 2. Y?".

**If Questions Arise**:
- Edit `plan.txt` with answers (e.g., prepend "Resolved: 1. Use HS256.").
- Re-run to update history.

**Post-Run**: Rename to `.aider.chat.history.md` for loop compatibility:
```bash
mv fresh_plan_history.md .aider.chat.history.md
```

### 2. Task Execution Loop (`task_execution_loop.sh`)
**Purpose**: Implement a task iteratively, with AI coding, auto-fixes, and gates. Restores history for context.

**Command**:
```bash
./task_execution_loop.sh <max_cycles> "<task_prompt>"
```
- **Args**:
    - `<max_cycles>`: Max iterations (e.g., 10; each = prompt + build + check).
    - `<task_prompt>`: Short goal (e.g., "Add JWT validation middleware").

**Example** (for Step 1 from plan):
```bash
./task_execution_loop.sh 5 "Implement JWT auth middleware per plan"
```

**Internal Workflow** (per cycle):
1. **Prompt (GPT-5-mini)**: "Continue working on this task: [prompt]. Make progress... Focus on clean code."
    - AI edits files based on history/plan.
2. **Build Check**: Runs `cargo build`; captures output.
    - If fails: Up to 5 fix prompts ("Fix these errors: [output]").
    - Loops until clean or max fixes (exits on failure).
3. **Completion Gate (Grok-4-fast)**: "Review changes... Respond: 'READY FOR TESTING' or 'QUESTIONS TO ANSWER: [list]'."
    - Ready: Exit 0 (success).
    - Questions: Exit 42 (log questions; human intervene).
    - Not ready: Next cycle.

**Output**:
- Edits committed? No (use `--no-auto-commits`); manual `git add . && git commit` post-run.
- Logs to `task_loop.log` (prompts, responses, build outputs).
- Temp files auto-cleaned.

**Advanced**:
- Customize build: Edit `BUILD_CMD="cargo test"` for tests.
- Resume: Re-run after answering questions (history persists).

## Full Workflow Example

For a multi-step plan (e.g., auth feature):
1. Write `plan.txt`: "Step 1: JWT middleware. Step 2: User routes..."
2. `./build_fresh_history.sh plan.txt files.txt && mv fresh_plan_history.md .aider.chat.history.md`.
3. If confident: `./task_execution_loop.sh 8 "Execute Step 1: JWT middleware"`.
4. If questions (exit 42): Answer in `plan.txt`, re-build history, resume loop.
5. Repeat for Step 2: Update prompt to "Execute Step 2: User routes".
6. Post-all: `git commit -m "Implemented auth per plan"`.

For orchestration, wrap in a master script:
```bash
#!/bin/bash
# orchestrator.sh
MAX_CYCLES=10
STEPS=("Step 1: JWT" "Step 2: Routes")
for step in "${STEPS[@]}"; do
  ./task_execution_loop.sh $MAX_CYCLES "$step"
  if [[ $? -eq 42 ]]; then
    echo "Paused for questions—resolve and re-run."
    exit 42
  fi
done
```

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| "Model not found" | OpenRouter key invalid | Check `echo $OPENROUTER_API_KEY`; test with `aider --model ...`. |
| Expect timeout/hang | Slow AI or network | Increase `timeout 300` to 600; check logs for "Timeout waiting...". |
| Parse fails (e.g., no "READY") | LLM phrasing variance | Tweak grep to `-Eiq "ready.*testing|complete"`. |
| History not loading | Wrong filename | Ensure `.aider.chat.history.md` in cwd; use `--chat-history-file` if custom. |
| Cargo fails repeatedly | Stubborn errors | Increase `max_fixes=5` to 10; manual intervene post-log. |
| Token overflow | Long history | Set `max_chat_history_tokens: 100000` in conf; monitor with `/tokens` in Aider. |
| Paths with spaces | xargs breaks | Quote files in `files_list.txt`; use arrays. |

- **Debug Mode**: Add `--dry-run` to Aider calls for previews.
- **Logs**: Always check `aider_setup.log`/`task_loop.log`—includes full prompts/responses.
- **Aider Docs**: [Interactive Mode](https://aider.chat/docs/interactive.html), [History](https://aider.chat/docs/history.html).

## Extending & Contributing

- **Adapt for Other Langs**: Swap `BUILD_CMD="npm test"` for JS; add parsers for outputs.
- **Model Swaps**: Edit `run_aider_prompt` env (e.g., Claude for code).
- **Enhancements**:
    - Integrate `cargo test` post-build.
    - JSON state file for resumption (e.g., current cycle/step).
    - Webhook for notifications on exits.
- **Contribute**: Fork, add features (e.g., PowerShell port), PR with tests. Use `bats` for script testing.

