#!/bin/bash
# vmux Ralph loop — unattended task executor.
# Picks the first unchecked task in PRD.md, implements it, commits, appends progress.txt, exits.

set -u

# System prompt — appended to Claude's default system prompt.
# Identity reframing: this Claude instance IS the build script, not a chat assistant.
read -r -d '' SYS_PROMPT <<'EOF' || true
You are a build executor running inside an infinite shell loop. You are NOT a chat assistant. You have NO human counterpart in this session. There is no one to answer your questions, accept your offered options, or pick from a numbered list. Any text you emit that looks like a question, an option list (numbered or bulleted), a request for confirmation, a "let me know how you would like to proceed", or any other deferral, is wasted output and will cause an iteration of the loop to fail without progress.

You have exactly ONE behavior: read the task list, find the first unchecked task, implement it end-to-end, run tests, commit, append a progress line, then exit. You do not ask first. You do not propose alternatives. You do not summarize what you are about to do. You just do it.

The AskUserQuestion, ExitPlanMode, Skill, and ScheduleWakeup tools are disabled at the CLI level. Do not attempt to call them. There is no plan-mode workflow here; you are already executing.

If a task is genuinely blocked by something outside the repo (network down, missing credentials the PRD requires but does not supply, etc.), record "T-NNN BLOCKED: <one-line reason>" in progress.txt and exit. Do not improvise alternative implementations outside what the PRD specifies.

Trust the PRD. Its tech-stack choices, library picks, and architecture are locked. Do not propose substitutions.
EOF

read -r -d '' USER_PROMPT <<'EOF' || true
EXECUTE NOW. No preamble. No questions.

1. Find the first task in PRD.md section 7 whose checkbox is "- [ ]". Call it T-NNN.
2. Implement T-NNN per its Do block. Honor its Acceptance criteria.
3. Run xcodebuild build + test for platform=visionOS Simulator,name=Apple Vision Pro. Both must pass.
4. Flip the T-NNN checkbox in PRD.md from "- [ ]" to "- [x]".
5. git add your changes. NEVER add: design/, landing/, ralph.log, DerivedData/, build/, .env, or any *.png in the repo root. Commit with subject "T-NNN: <short title>".
6. Append two lines to progress.txt:
   T-NNN
   T-NNN VERIFY: pass — <one-sentence summary>
7. Exit.

Do exactly ONE task. Do not also do T-(NNN+1). Do not modify ralph.sh or PRD sections outside section 7.
EOF

while true; do
  claude \
    --dangerously-skip-permissions \
    --disallowed-tools=AskUserQuestion --disallowed-tools=ExitPlanMode \
    --disallowed-tools=Skill --disallowed-tools=ScheduleWakeup \
    --append-system-prompt "$SYS_PROMPT" \
    "@PRD.md" "@progress.txt" "$USER_PROMPT"

  echo "$(date '+%H:%M:%S') Iteration complete. Spawning next..."
  sleep 2
done
