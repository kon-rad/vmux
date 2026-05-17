#!/bin/bash
while true; do
  claude --permission-mode acceptEdits "@PRD.md" "@progress.txt" \
  "1. Read the PRD.md and progress.txt files.
   2. Find the next incomplete task and implement it.
   3. Run your tests to verify the fix.
   4. Commit your changes via git.
   5. Append the completed task to progress.txt.
   ONLY DO ONE TASK AT A TIME. Exit when done."

  echo "Iteration complete. Spawning next fresh context loop..."
  sleep 2
done
