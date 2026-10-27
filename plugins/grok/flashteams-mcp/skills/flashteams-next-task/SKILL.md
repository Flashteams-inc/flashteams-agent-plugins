---
name: flashteams-next-task
description: Pick up your next FlashTeams task and work it through to a plain-language handoff. Use when the person asks for their next task, what to work on next, or to pick up their FlashTeams work.
---

# Work your next FlashTeams task

This uses the tools of the `flashteams` MCP server. If they say you are not
signed in, ask the person to sign in (Claude Code: `/mcp`, choose
flashteams, then Authenticate; Codex: `codex mcp login flashteams`) and stop.

1. **Find the task.** Call `find_tasks`; it lists the tasks assigned to you.
   If the person named a task, use that one. Otherwise prefer work you
   already started (`in_progress`), then `todo`. Skip tasks blocked by
   unfinished work. If no project is connected, call `list_my_projects`, then
   `connect_workspace`, and ask the person when more than one project fits.
   If nothing is left, say so and stop.
2. **Read the briefing.** Call `load_task` with the task id. Read
   `prior_knowledge` first and never repeat an experiment it marks as
   failed. Only work a task assigned to you, unless the person tells you to
   take it over.
3. **Start before working.** Call `update_task` with action `start` before
   you change anything, so the time you spend is measured.
4. **Do the work** the task asks for, and run the project's checks.
5. **Close with a handoff.** Call `update_task` with action `close` (or
   `submit_for_review` when someone has to review it) and write the note in
   plain language: what you did, what is done and what is left, where to
   pick up, how to check it works, and anything to watch out for. Leave
   `actual_hours` out so the measured time stands. Pass it only when that
   time is wrong, for example when the task sat started while nobody worked
   on it, and then give the real time worked, never an estimate.
