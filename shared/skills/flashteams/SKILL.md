---
name: flashteams
description: Use FlashTeams through the flashteams command that Flash Console provides. Load this for anything about FlashTeams projects, tasks, phases or programs, the exploration graph, FlashBrain, recipes, or questions about the organization's code graph, such as finding, starting, updating or closing a task, reading a project's plan, or asking how a piece of the code fits together.
---

# FlashTeams through the flashteams command

Inside Flash Console this session has the `flashteams` command. Every
FlashTeams tool is one of its subcommands, and each runs with the
FlashTeams sign-in of the person using Flash Console, so there is nothing
to sign in to and no token to handle. The briefing at the start of the
session says whose sign-in it is, which task the person chose in Flash
Console, if any, and how FlashTeams expects you to work. Follow it.

## Find the tools

```sh
flashteams tools               # every tool, one line each
flashteams help load_task      # what one tool does, its arguments, an example
```

Each argument is a flag named as `flashteams help <tool>` shows it:

```sh
flashteams find_tasks --status in_progress
flashteams load_task --task_id <task id>
flashteams update_task --task_id <task id> --action start
```

- Run `flashteams help <tool>` before you first use a tool, and pass only
  the arguments it lists. `--name value` and `--name=value` both work.
- A list takes its flag once per value, or a JSON array. An object takes
  JSON. `--json '{...}'` passes all the arguments at once.
- `--output json` prints the whole answer as JSON.
- If `flashteams` is not found, run the full path the briefing gives.
- Read each answer. A tool can turn a request down in its answer, for
  example with `"success": false` and a message, and the command still
  exits 0.

## Long text

Give `-` as the value to read that argument from standard input. Use it
for handoffs, notes and anything longer than a line, with a quoted
here-document so the shell changes nothing:

```sh
flashteams update_task --task_id <task id> --action close --closing_note - <<'EOF'
What I did, what is finished and what is left, where to pick up,
how to check it works, and anything to watch out for.
EOF
```

Flash Console limits how long one command can be, text from standard input
included. If it says the request is too long, shorten the text, or send it
in parts, for example as several pieces of evidence.

## The working loop

1. `connect_workspace` to the project, then `load_project`.
2. `load_task`, and read `prior_knowledge` first. Never repeat an
   experiment it marks as failed. Only work a task assigned to you, unless
   the person tells you to take it over. `load_task` finds only tasks in
   the connected project: for the task chosen in Flash Console, connect to
   the project the briefing names, and if it names none, ask the person
   which project it is in rather than trying projects one by one.
3. `update_task --action start` before you change anything, so the time
   you spend is measured.
4. Do the work, and run the project's checks.
5. Finish with `update_task --action submit_for_review` (with `--summary`)
   or `--action close` (with `--closing_note`). Write the handoff in plain
   language: what you did, what is done and what is left, where to pick
   up, how to check it works, and anything to watch out for.

Never invent hours. Leave `actual_hours` out so the measured time stands.
Pass it only when that time is wrong, for example when the task sat
started while nobody worked on it, and then give the real time worked,
never an estimate.

Ask the person before you run `complete_project`, `complete_phase` or
`respond_to_approval`, unless they already told you to. The first two
close work for the whole team, and the last decides for a FlashBrain run;
none is easy to undo.

## When a command fails

The error is one line on stderr, written for the person. The exit code
says what kind of failure it is:

| Exit | Meaning | What to do |
| :- | :- | :- |
| 0 | Done. | Read the answer: the tool may still have said no in it. |
| 1 | FlashTeams or the tool said no, or the person declined. | Read the message. Do not repeat the same call unchanged. |
| 2 | The command was wrong, or too long. | Check `flashteams help <tool>`, or shorten the text. |
| 3 | Flash Console is not running, is too old, or a sandbox blocked it. | If the briefing gave the command's full path, run the same command once with that path in place of `flashteams`. If that fails too, tell the person. See below for sandboxes. |
| 4 | FlashTeams for agents is off or read only in Flash Console, or nobody is signed in. | Tell the person what the message says. Do not work around it. |
| 5 | Flash Console was busy, it took too long, or the network failed. | See below. Never repeat a change before checking it did not happen. |

After exit 5:

- **Busy**, when the message says Flash Console or FlashBrain is already
  answering, or too many calls were made: nothing ran. Wait a little and
  run it again.
- **A tool that only reads:** run it once more.
- **A tool that changes FlashTeams**, such as `update_task`,
  `create_task` or `graph_action`: the change may have been made before
  the time ran out. Check first with a read (`load_task`, `find_tasks`,
  `get_events` or `get_findings`) and run it again only if the change is
  not there.
- **`ask_flashbrain` that took too long:** never ask again, which would
  start a second, paid run. The first run carries on. Check
  `list_pending_approvals`, and `get_flashbrain_answer` with the
  `session_id` if you have one.

## Sandboxes

The command reaches Flash Console through a private socket on this
computer, which an agent's sandbox can block. The message then says so.

- **Codex:** run the same command again, asking to run it outside the
  sandbox, and the person approves it.
- **Claude Code:** the person adds the Flash Console socket to
  `sandbox.network.allowUnixSockets` in their settings.

Never ask for a FlashTeams token or handle one. Use the `flashteams`
command, or the FlashTeams MCP tools when the optional `flashteams-mcp`
plugin gives you them.
