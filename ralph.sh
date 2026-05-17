#!/bin/bash
# vmux Ralph loop — unattended task executor.
# Picks the first unchecked task in PRD.md, implements it, commits, appends progress.txt, exits.

set -u

while true; do
  claude \
    --dangerously-skip-permissions \
    --disallowed-tools "AskUserQuestion,ExitPlanMode,Skill,ScheduleWakeup" \
    "@PRD.md" "@progress.txt" "$(cat <<'PROMPT'
You are running inside an unattended automation loop. The user is NOT here and CANNOT answer questions. Any attempt to ask will return an empty dismissal and waste an iteration.

The AskUserQuestion, ExitPlanMode, Skill, and ScheduleWakeup tools are DISABLED at the CLI level — calling any of them will error. Do not call them. Do not call any tool whose purpose is to pause for human input.

Do NOT ask questions. Do NOT present numbered options ("1. ... 2. ... 3. ..."). Do NOT request confirmation. Do NOT propose alternatives. Do NOT say "let me know how you'd like to proceed". Just execute.

EXECUTE THESE STEPS, IN ORDER, EXACTLY ONCE, THEN EXIT:

1. Read PRD.md and progress.txt.
2. In PRD.md §7 Task List, find the FIRST task whose checkbox is "- [ ]". Call it T-NNN.
3. Implement T-NNN end-to-end per its "Do" block. Follow the Acceptance criteria.
4. Run any tests or verification commands the task requires. Use `xcodebuild` for build/test (sandbox is bypassed; just run it).
5. In PRD.md, flip the checkbox for T-NNN from "- [ ]" to "- [x]".
6. `git add` all your changes (do NOT add: design/, landing/, ralph.log, DerivedData/, build/). Create a single commit with subject "T-NNN: <short title>".
7. Append exactly two lines to progress.txt:
   T-NNN
   T-NNN VERIFY: pass — <one-sentence summary of how you verified>
8. Exit immediately. Do not summarize. Do not ask what's next.

RULES:
- If T-NNN is genuinely blocked (e.g. external service unreachable), append "T-NNN BLOCKED: <reason>" to progress.txt instead, commit any partial work with subject "T-NNN (blocked): <reason>", and exit. Do not invent workarounds outside the PRD.
- Stay within scope of T-NNN. Do not also do T-(NNN+1).
- Do not modify ralph.sh, PRD.md sections outside §7, or files outside the repo.
- Trust the PRD's tech choices. Do not propose alternatives.
PROMPT
)"

  echo "$(date '+%H:%M:%S') Iteration complete. Spawning next..."
  sleep 2
done
