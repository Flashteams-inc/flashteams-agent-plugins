---
name: flashteams
description: Use FlashTeams through the flashteams command that Flash Console provides. Load this for anything about FlashTeams projects, tasks, phases or programs, the exploration graph, FlashBrain, recipes, or questions about the organization's code graph, such as finding, starting, updating or closing a task, reading a project's plan, or asking how a piece of the code fits together.
allowed-tools: Bash(flashteams:*)
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

## The working loop

1. `connect_workspace` to the project, then `load_project`.
2. `load_task`, and read `prior_knowledge` first. Never repeat an
   experiment it marks as failed. Only work a task assigned to you, unless
   the person tells you to take it over.
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

## When a command fails

The error is one line on stderr, written for the person. The exit code
says what kind of failure it is:

| Exit | Meaning | What to do |
| :- | :- | :- |
| 0 | Done. | |
| 1 | FlashTeams or the tool said no, or the person declined. | Read the message. Do not repeat the same call unchanged. |
| 2 | The command was wrong. | Check `flashteams help <tool>`. |
| 3 | Flash Console is not running, is too old, or a sandbox blocked it. | Tell the person. See below for sandboxes. |
| 4 | FlashTeams for agents is off or read only in Flash Console, or nobody is signed in. | Tell the person what the message says. Do not work around it. |
| 5 | It took too long, Flash Console was busy, or the network failed. | Wait a moment and try once more. |

## Sandboxes

The command reaches Flash Console through a private socket on this
computer, which an agent's sandbox can block. The message then says so.

- **Codex:** run the same command again, asking to run it outside the
  sandbox, and the person approves it.
- **Claude Code:** the person adds the Flash Console socket to
  `sandbox.network.allowUnixSockets` in their settings.

Never try to reach FlashTeams another way, and never ask for a token.
