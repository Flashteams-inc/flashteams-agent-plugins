# FlashTeams agent plugins

Plugins that connect Claude Code and Codex to FlashTeams. One repository
serves both: a Claude Code marketplace and a Codex marketplace, each named
`flashteams`, each with two plugins.

**`flashteams`** works with Flash Console, the FlashTeams terminal, and
needs no sign-in of its own. It gives the agent:

- **Every FlashTeams tool, as the `flashteams` command.** Flash Console
  provides the command and runs each tool with the FlashTeams sign-in you
  already have in Flash Console, so the agent never holds a token. The
  agent runs `flashteams tools` for the list and `flashteams help <tool>`
  for a tool's arguments. Flash Console puts the command on the PATH of
  every shell it starts; in Claude Code the plugin also puts it on the Bash
  tool's PATH.
- **A briefing when a session starts:** whose sign-in the command uses,
  the task you chose in Flash Console, how to use the command, and how
  FlashTeams expects agents to work. Nothing else is loaded up front; the
  agent looks up projects and tasks with the tools when it needs them.
- **The `flashteams` skill**, which teaches the agent the command and the
  FlashTeams way of working a task.
- **No Claude Code permission prompt for the `flashteams` command.** Flash
  Console already asks you before the actions that need it, so Claude Code
  does not ask a second time. See [Permission prompts](#permission-prompts).
- **Agent status for Flash Console.** Small hooks tell Flash Console when
  the agent starts, is working, needs your permission or an answer, is done
  or failed, so the agent's tab shows it, and how far the agent got through
  its to-do list, so Flash Console's plan chip can show it.
- **Security, SQL and architecture audits** of the repository you are in,
  run on your computer and recorded in FlashTeams. See
  [Audits](#audits).

**`flashteams-mcp`** is optional. It adds the FlashTeams MCP server, which
you sign in to with your own FlashTeams account, and the
`flashteams-next-task` skill that uses it. Use it for an agent outside
Flash Console, or if you prefer MCP. You can install `flashteams` alone.

On macOS and Linux the hooks need Perl, which comes with macOS. On Windows
they need no Perl: they hand each hook to Flash Console's own
`flashteams.exe`, and Claude Code needs Git for Windows to run them (see
[Windows](#windows)). Without Perl on a Mac, without Flash Console, or
with anything else missing, they quietly do nothing.

## Install

### Claude Code

```sh
claude plugin marketplace add Flashteams-inc/flashteams-agent-plugins
claude plugin install flashteams@flashteams
# Optional: the MCP server
claude plugin install flashteams-mcp@flashteams
```

Start a new Claude Code session, or run `/reload-plugins` in an open one.

### Codex

```sh
codex plugin marketplace add Flashteams-inc/flashteams-agent-plugins
codex plugin add flashteams@flashteams
# Optional: the MCP server
codex plugin add flashteams-mcp@flashteams
```

Start a new Codex session. Then trust the hooks, as below.

## Sign in

- **`flashteams`:** sign in to FlashTeams in Flash Console. There is
  nothing to sign in to in the agent. Flash Console's Settings, under
  Agents, decides what agents may do with FlashTeams: nothing, read only,
  or read and update.
- **`flashteams-mcp`:** in Claude Code, run `/mcp`, choose `flashteams`,
  then **Authenticate**, and sign in with your FlashTeams account in the
  browser. In Codex, run `codex mcp login flashteams`.

## Permission prompts

Flash Console asks you before the `flashteams` actions that need it:
closing a project or phase, editing documentation, asking FlashBrain, and
answering a FlashBrain approval. If you say no, the command exits 1 and
the skill tells the agent not to try again unless you ask.

- **Claude Code:** does not ask before a `flashteams` command, so you are
  never asked twice. The skill's `allowed-tools` is `Bash(flashteams:*)`,
  but Claude Code keeps that only for the turn that loads the skill, so the
  plugin also has a permission check: a `PreToolUse` hook on the Bash tool
  that lets one plain `flashteams` command run without a prompt. Anything
  more, such as `cd x && flashteams tools`, a pipe, a redirection or
  `$(...)`, gets Claude Code's usual prompt. So does any command in plan
  mode, and any command Claude Code wants to run outside its sandbox. Your
  own deny and ask rules still apply: for example, an ask rule for
  `Bash(flashteams update_task:*)` brings the prompt back for that tool.
  The exact rules are in [The permission check](#the-permission-check).
- **Codex:** unchanged. Codex asks before running the command outside its
  sandbox (see below), and Flash Console asks as above.

In a Flash Console pane, Claude Code's own questions also show as a card
with buttons on the pane, so you can answer with a click as well as with
the keyboard: a tool it wants to use (Allow, Deny), and an MCP server
asking to go ahead with nothing to fill in, such as the Supabase server
before destructive SQL (Accept, Decline). Answer in the terminal leaves the
question to Claude Code's own prompt. See [The asks](#the-asks).

## Audits

From 1.8.0 the `flashteams` plugin has three audit skills, for both agents.
In Claude Code they are commands:

| Command | What it does |
| :- | :- |
| `/flashteams:security-audit` | Scans for committed secrets and FlashTeams' security and hotspot code rules; in full mode also infrastructure files and dependency vulnerabilities. The agent judges each finding, dismisses false positives, and writes a report with a fix-first list. |
| `/flashteams:sql-audit` | Runs FlashTeams' SQL rules (`.sql` files, and SQL and NoSQL injection in application code) and checks `.sql` files for secrets, then reviews what rules cannot judge: tables without row-level security, grants to everyone, `SECURITY DEFINER` functions without a fixed `search_path`, personal data stored as plain text, dynamic SQL in stored procedures, and database passwords. Ends with a remediation list ordered by risk. |
| `/flashteams:architecture-review` | Runs no scanners. Uses the product's FlashTeams code map when there is one (`code_map`, `query_codebase`, `read_docs`), otherwise reads the repository, and writes a report a new engineer can follow: the main parts, how data flows, where the auth boundaries are, then the risks (cycles, modules everything leans on, dead code, coupling, hard-to-reverse choices, bottlenecks). |

In Codex, ask for a security audit, a SQL audit or an architecture review,
or name the skill.

Each skill runs the plugin's helper, `scan/flashteams-scan.pl`, a Perl
program (Perl 5.14 or later, with the modules that ship with it, git, and
curl for downloads):

```sh
perl flashteams-scan.pl doctor [--json]        # which scanners are here, and how to install the missing ones
perl flashteams-scan.pl install <tool>...      # gitleaks, opengrep, trivy: pinned versions, checked
perl flashteams-scan.pl rules                  # FlashTeams' rules, through get_scan_rules
perl flashteams-scan.pl run --kind security|sql [--mode quick|full] [--path <folder>] --rules <folder> --out <work folder>
perl flashteams-scan.pl show --out <work folder> --ids 3,12   # findings in full, with the code around them
perl flashteams-scan.pl payload --out <work folder> --kind ... --summary-file ... --report-file ... [--notes ...]
perl flashteams-scan.pl send --out <work folder> [--product-id <id>]   # record_code_scan, through the flashteams command
```

- **The scanners** are gitleaks 8.30.1 (secrets), opengrep 1.30.0
  (FlashTeams' code rules; semgrep runs them in its place when opengrep is
  missing) and Trivy 0.74.0, the versions FlashTeams' own scanner uses.
  The agent offers to install what is missing and waits for your yes.
  `install` downloads each from its GitHub release into
  `~/.flashteams/tools/bin` (or `FLASHTEAMS_TOOLS_DIR`) for macOS or Linux
  on arm64 or x64, checks it against a pinned checksum, and changes nothing
  else; on a Mac, `brew install gitleaks trivy` works too. On Windows,
  `install` points to the release pages instead.
- **FlashTeams' rules** come from the `get_scan_rules` tool, which gives a
  link that works once, within two minutes, and says nothing about who
  asked. The helper checks the download against
  its checksum, refuses any file in it that would land outside its folder,
  and keeps it in `~/.flashteams/scan-rules` (or `FLASHTEAMS_RULES_DIR`).
  Without the rules, gitleaks and Trivy run with their own, and opengrep is
  recorded as skipped.
- **The work folder** is under your system's temporary folder,
  `flashteams-scan/<repository>-<kind>-<date>-<time>`, never inside the
  repository. It holds the helper's files, the agent's notes, and the
  report, which the agent copies into the repository only if you ask.
- **Results go to FlashTeams** with `record_code_scan`, through the
  `flashteams` command, or through the FlashTeams MCP tools when the
  `flashteams-mcp` plugin gives them. They show beside the scan FlashTeams
  runs, and never replace it. The answer says what is new and what was
  fixed since the last scan. If FlashTeams does not know which product the
  checkout belongs to, the agent asks you and sends again. It offers to
  file tasks for the critical and high findings (`file_scan_tasks`) and to
  fix them, and does either only after you agree. Without the command or
  the MCP tools, the report stays on your computer.

**What never leaves your computer:** your code; any secret's value, which
the helper never prints or writes (gitleaks runs with `--redact`, its
`Secret` and `Match` fields are dropped as they are read, and `show` prints
`[hidden]` in its place); the scanners' own reports, which quote the code
and are deleted once read; and the folders and user name of your computer.
What is sent is `payload.json` in the work folder, which you can read
first: each finding's rule, file path, line, severity and the rule's
words or the agent's notes, the tools that ran, the summary and report the
agent wrote, and git's facts about the checkout: the remote address with
any user name or password taken out, the branch, the commit, and whether
there were changes not committed.

The scanners run on your computer. gitleaks and opengrep use no network;
opengrep keeps its own unpacked program files in `~/.cache/opengrep`.
Trivy's infrastructure check runs offline, and its dependency check, in
full mode only, downloads Trivy's vulnerability database (several hundred
MB the first time, kept in Trivy's cache or `FLASHTEAMS_TRIVY_CACHE`).
Trivy runs with its usage data turned off.

## Visual QA

From 1.9.8 the `flashteams` plugin has a `visual-qa` skill, for both
agents: `/flashteams:visual-qa` in Claude Code, and in Codex ask for a
visual QA of the branch or name the skill. Flash Console's `/visual-qa`
starts it in a pane with the agent Settings names for requests.

It draws a change twice in Flash Console's Diagrams: Current is the code
at the commit the branch left its base, the same one a pull request is
compared with, and a scenario is the code as the branch leaves it.
Diagrams marks each part and link the scenario adds, changes or removes,
and the agent writes a review for each: what changes, why, what it could
not settle, the risk, and the checks to run, each with what should
happen. Every changed file is drawn, set aside with a reason (tests,
docs, generated files) or named as not explained.

What it compares follows the words after the command: nothing for this
branch against the default branch, a branch or ref, a pull request number
(with `gh`, or `git fetch origin pull/<n>/head`), or work in progress for
the uncommitted changes too. Anything else is a focus. The skill reads git
only: it changes no code and never commits. It needs Flash Console's own
MCP server, `flash-console`, whose `diagram__` tools draw the diagram;
without it the agent says so and lists the changes in words.

From 1.9.9 the skill tells Flash Console what the scenario compares
(`compared` on `add_scenario`: the base branch and its commit, the branch
and its commit) and sets files aside on the scenario itself. Flash Console
then reads git for the changed files, shows each part's real diff in its
review, counts what the drawing explains in a row over it, and marks the
cards in Code review, whose Visual QA button starts the skill too. Such a
scenario offers no Build this change or Merge into Current: its code is
written already.

## Roadmap

From 1.10.0 the `flashteams` plugin has a `roadmap` skill, for both
agents: `/flashteams:roadmap` in Claude Code, and in Codex ask to add a
feature to the roadmap or name the skill. It works FlashTeams' Roadmap,
where a roadmap holds features and each feature is tied to the projects,
tasks, Flash Design spaces, analyses, diagrams and FlashBrain chats about
it, through the roadmap tools of the `flashteams` command or the FlashTeams
MCP tools (`roadmap_search`, `roadmap_feature`, `roadmap_candidates`,
`roadmap_tag`, `roadmap_create_feature`, `roadmap_update_feature` and
`roadmap_create`).

The agent finds a feature before acting on one, and adds a feature or
starts a roadmap only when you ask. It tags a Flash Design space it makes
for a feature's work to that feature (the `flash-design` skill says so
too), an analysis or a diagram once you have shared it to FlashTeams from
Flash Console, which no agent tool does, and a chat, a task or a project
when you say it is part of the feature. It marks a feature shipped only
when you say it is done or live. Owners, executives, admins and project
managers add and change features; Builders tag their own work.

From 1.10.1 the skill says that `track_work` and `create_task` check the
roadmap for each task they make. A standalone task that clearly belongs to
a feature is linked to it and becomes visible to the team instead of
personal. A task whose project is on a feature is part of it through that
project. Otherwise their answer lists the features the task might be part
of, and the agent tags one with `roadmap_tag` only once you confirm it.

## Sandboxes

The `flashteams` command reaches Flash Console through a private socket on
your computer (a named pipe on Windows), and an agent's sandbox can block
that. The command then says so and exits 3.

- **Codex:** its default sandbox blocks the socket. Approve running
  `flashteams` outside the sandbox when Codex asks.
- **Claude Code:** with its sandbox on, add the Flash Console socket (see
  [Where](#where)) to `sandbox.network.allowUnixSockets` in your settings.

The hooks are not affected: both agents run hooks outside the sandbox.

## Trust the hooks in Codex

Codex does not run a plugin's hooks until you have looked at them. After
installing, start `codex`, run `/hooks`, review the FlashTeams hooks and
trust them. Codex asks again if an update changes them. Until then Codex
works as usual, but Flash Console does not see its status and Codex gets
no briefing.

Claude Code needs no extra step: the hooks run once the plugin is enabled.

## Windows

On Windows the hooks need no Perl. Each one hands the agent's input to
Flash Console's own program, `flashteams.exe`, which talks to Flash Console
through its named pipe:

```text
flashteams.exe --hook <agent> <hook-event>
```

The program is found in `%FLASH_CONSOLE_BIN%`, which Flash Console sets in
every shell it starts, else in `%LOCALAPPDATA%\Flash Console\bin`, and only
by a full path on this PC, so a folder named relative to where the agent
works, or one on another computer (`\\server\share\...`), is never used.
When it is not there, Flash Console is not installed, and the hooks quietly
do nothing.

- **Claude Code** needs Git for Windows. Claude Code runs its hook commands
  in Git Bash when it finds it, and the starter then runs `flashteams.exe`.
  Without Git Bash, Claude Code runs them in PowerShell, and the hooks do
  nothing: no agent status and no briefing. Claude Code's Bash tool, Git
  Bash too, finds the `flashteams` command through the plugin's shim; its
  PowerShell tool finds `flashteams.exe` only in a Flash Console shell, whose
  `PATH` includes it.
- **Codex** needs version 0.131 or later, the first to read
  `commandWindows`, the command it runs in place of `command` on Windows.
  Codex runs it in PowerShell. It is one line that uses only PowerShell's
  own commands, with no file from the plugin and no `${...}` for Codex to
  fill in, so neither PowerShell's execution policy nor its Constrained
  Language Mode stops it.
- **Flash Console** needs a Windows version with the agent connection and
  `flashteams.exe`. The first Windows preview has neither, so there the
  hooks do nothing yet.

An agent run inside WSL is a Linux program, with the plugin installed in
WSL itself (the commands above, run there). From 1.6.0, in a Flash Console
pane running WSL, which names the folder of `flashteams.exe` in
`FLASH_CONSOLE_BIN` as Linux sees it (`/mnt/c/...`, through `WSLENV`), its
hooks hand every event and the briefing request to that `flashteams.exe`,
which WSL runs on Windows with the pane's variables, so the agent gets its
status and its briefing as on Windows. Claude Code's permission check still
runs in Perl, which needs no connection, and the `flashteams` command runs
`flashteams.exe` the same way. A relative `FLASH_CONSOLE_BIN` is never
used, and WSL started anywhere else has none, so its hooks do nothing.

Not yet tried on a real Windows PC (the tests run every command on a Mac,
as Git Bash runs it, and in PowerShell 7 where it is installed):

- that Windows PowerShell 5.1 ends a command at `$(exit 0)` with exit 0 and
  prints nothing;
- that `flashteams.exe`, started from PowerShell, gets the agent's input
  byte for byte, and that its answer reaches the agent unchanged;
- how Git Bash reads the command line Claude Code builds for these
  commands, with their quotes inside quotes;
- the folders each agent installs plugins into on Windows;
- how long each hook takes there: Git Bash starts several programs for each
  hook, and PowerShell takes a moment to start.

Codex runs hook commands in `cmd.exe` instead when it finds no PowerShell
at all. The Windows commands are PowerShell, so they would fail there.

## Update

Claude Code:

```sh
claude plugin marketplace update flashteams
claude plugin update flashteams@flashteams
```

Codex:

```sh
codex plugin marketplace upgrade flashteams
codex plugin add flashteams@flashteams
```

Restart the agent afterwards. In Codex, check `/hooks` in case the update
changed the hooks.

**Coming from 1.7.0:** the `flashteams` plugin gains the security, SQL and
architecture audits (see [Audits](#audits)) and the scan helper they run.
The hooks are unchanged.

**Coming from 1.4.0:** the hooks also tell Flash Console the agent's plan:
Claude Code's to-do list or tasks, and Codex's plan, step by step, so Flash
Console's plan chip shows how far the agent got ("Plan 3 of 5") and lists
the steps. Older Flash Console versions ignore it. The commands in
`hooks.json` are unchanged; only the hook program learned the plan.

**Coming from 1.2.0:** nothing changes on a Mac. The hooks gain a Windows
path (see [Windows](#windows)). Codex 0.160 does not ask you to trust the
hooks again on a Mac, because it leaves the Windows commands out of what it
checks there; an older Codex may ask once.

**Coming from 1.1.0:** Claude Code stops asking before each `flashteams`
command once the update is installed and Claude Code restarted. Flash
Console keeps asking before the actions that need it. Codex is unchanged.

**Coming from 1.0.0:** the MCP server moved from `flashteams` to the new
`flashteams-mcp` plugin. Inside Flash Console the `flashteams` command does
the same work without it. To keep the MCP server as well, install
`flashteams-mcp` as above, and sign in to it again if the agent asks.

## Remove

Claude Code:

```sh
claude plugin uninstall flashteams@flashteams
claude plugin uninstall flashteams-mcp@flashteams
claude plugin marketplace remove flashteams
```

Codex:

```sh
codex plugin remove flashteams@flashteams
codex plugin remove flashteams-mcp@flashteams
codex plugin marketplace remove flashteams
```

To also sign the MCP server out of FlashTeams: in Claude Code, `/mcp`,
choose `flashteams`, then **Clear authentication**; in Codex,
`codex mcp logout flashteams`.

## Privacy

- The hooks talk only to Flash Console on this computer, through a private
  socket in your own user folder that only you can open. On Windows,
  Flash Console's `flashteams.exe` does this for them, through a named pipe
  that only you can open. The hooks make no network connections.
- When Flash Console is not running, nothing is sent and nothing is kept.
- An event holds what Flash Console needs to show status: the agent, what
  happened, the session id, the working folder and its project name, the
  tool name, the id of the subagent involved, short excerpts of the
  prompt, reply, question or tool input, and the agent's to-do list: each
  step's words and whether it is done. Excerpts are at most 320 characters,
  a step's words at most 160, each on one line, with control characters and
  invisible characters removed.
- A briefing request holds the agent, the working folder, the pane and why
  the session started.
- The only things the hooks ever print for the agent to read are the
  briefing, once, when a session starts, or a short note that Flash
  Console could not send it, and in Claude Code the answer that lets a
  plain `flashteams` command run without a prompt. They never write to
  your terminal and never slow the agent down for more than a moment; a
  session start waits at most a second and a half for the briefing.
- The permission check reads only what Claude Code tells it about the
  Bash command. It sends Flash Console nothing.
- The `flashteams` command talks only to Flash Console, which calls
  FlashTeams with your sign-in. Your tokens stay in Flash Console; neither
  the command nor the agent ever sees them.
- The MCP server in `flashteams-mcp` is separate: the agent talks to
  FlashTeams with your own account only when it uses a FlashTeams tool.
- The audits' scan helper sends only what [Audits](#audits) describes, and
  only when the agent records a scan. It never prints or keeps a secret's
  value.

## The protocol (version 1)

What the hooks send and receive, for anyone building or checking the other
side.

### Where

A Unix socket that Flash Console creates when it starts and removes when it
quits (a file left by a crash is replaced):

1. `$FLASH_CONSOLE_AGENT_SOCKET`, when it is set to an absolute path;
2. else on macOS, `$HOME/Library/Application Support/Flash Console/agent.sock`;
3. else `${XDG_RUNTIME_DIR:-$HOME/.local/state}/flash-console/agent.sock`.

The folder is mode 0700 and the socket 0600. The hook only connects to a
socket owned by the person running it.

On Windows, a named pipe that Flash Console creates when it starts and that
goes away when it quits, crash included:

1. `%FLASH_CONSOLE_AGENT_SOCKET%`, when it is `\\.\pipe\` and then a name
   alone: no `\` or `/` in it, and not `.` or `..`, since Windows would
   otherwise read the rest as a path that leaves the pipes;
2. else `\\.\pipe\flash-console-agent-<SID>`, where `<SID>` is the
   person's security identifier in its usual text form, such as
   `S-1-5-21-1004336348-1177238915-682003330-1001`: the `TokenUser` of the
   process's own token, written out by `ConvertSidToStringSidW`. Pipe names
   are shared by everyone on the PC, so the name is per person.

Flash Console creates the pipe with the person's SID as its owner and as the
only one let in (`O:<SID>D:P(A;;GA;;;<SID>)`), with
`FILE_FLAG_FIRST_PIPE_INSTANCE`, so it fails when anyone else already holds
the name, and `PIPE_REJECT_REMOTE_CLIENTS`. A client connects with
`SECURITY_IDENTIFICATION` and sends nothing unless what it opened is a pipe
(`GetFileType` gives `FILE_TYPE_PIPE`, as the hook on a Mac checks it
found a socket) and the pipe's owner is its own SID. The owner alone does not
show the pipe is Flash Console's: a program of the same person running in a
sandbox with a restricted token could make the pipe first while Flash
Console is closed, and it would carry the same owner. So the client also
checks the process serving the pipe (`GetNamedPipeServerProcessId`): its
token's user is the same SID, it is not a restricted token, and its
integrity is medium or higher. Anything it cannot check counts as not Flash
Console. The lines on the pipe are the same as on the socket.

### How

For a status event the hook connects, writes one line, a single JSON
object of at most 8192 bytes ending in a newline, and closes. Flash Console
does not reply. If the socket is missing, refused or slow, the hook gives up
after 200 ms and exits 0 without a word. It never blocks the agent, never
needs `jq`, and reads at most 1 MB of the agent's hook input.

At a session start the hook then asks for the briefing on a second
connection; see [The briefing](#the-briefing).

Each agent starts the hook through `flashteams-hook.sh`, which runs the Perl
program with its stderr discarded, and its stdout too for every hook but
the session start and Claude Code's permission check, and then exits 0
whatever Perl did. Claude Code's asks run Flash Console's own program
instead of Perl; see [The asks](#the-asks). So when Perl cannot
compile the program, lacks a module it needs, or is killed, the agent never
sees a hook error. The starter first turns off the shell options `errexit`,
`nounset` and `xtrace`, which bash takes from an exported `SHELLOPTS`, so
they cannot make it fail or print a trace. On Windows, which sets `OS` to
`Windows_NT`, it runs Flash Console's `flashteams.exe` instead of Perl, in
the same way; see [Windows: flashteams.exe --hook](#windows-flashteamsexe---hook).

Every command in `hooks.json` starts the starter through a short guard:

```sh
$(exit 0); sh -c '{ set +eux; } 2>/dev/null; f=$1; shift; [ -r "$f" ] || exit 0; sh "$f" "$@" >/dev/null 2>&1; exit 0' \
  sh "${CLAUDE_PLUGIN_ROOT}/hooks/flashteams-hook.sh" claude Stop
```

The session start's guard keeps stdout, for the briefing, and so do the
guards of Claude Code's permission check and its asks, with
`flashteams-permission`, `ask-permission` or `ask-elicitation` in place of
`SessionStart`:

```sh
$(exit 0); sh -c '{ set +eux; } 2>/dev/null; f=$1; shift; [ -r "$f" ] || exit 0; sh "$f" "$@" 2>/dev/null; exit 0' \
  sh "${CLAUDE_PLUGIN_ROOT}/hooks/flashteams-hook.sh" claude SessionStart
```

Codex uses `${PLUGIN_ROOT}` in place of `${CLAUDE_PLUGIN_ROOT}`, and its
commands do not start with `$(exit 0); `. When Codex updates the plugin, it
deletes the old plugin folder but keeps running the hook commands it read
earlier, which name files in that folder, and `sh` on a missing file prints
an error and exits non-zero. The guard exits 0 without a word when the
starter is missing or cannot be read.

`$(exit 0); ` in front of Claude Code's commands is for Windows. In `sh`,
`bash` and `zsh` it does nothing. Claude Code on a Windows PC without Git
Bash runs its hook commands in PowerShell, which has no `sh`, so each would
fail with an error on every event; in PowerShell `$(exit 0)` ends the run
there, with exit 0, so the hooks quietly do nothing instead. Claude Code
has no field for a separate Windows command, so one command has to serve
both.

### Fields

Only `event` is required. Fields with nothing to say are left out.

| Field | Meaning |
| :- | :- |
| `v` | Protocol version, `1`. Receivers drop versions they do not speak. |
| `agent` | `claude` or `codex`. |
| `event` | What happened; see the next table. Receivers ignore events they do not know. |
| `session_id` | The agent's id for its conversation. |
| `cwd` | The agent's working folder. |
| `pane` | The Flash Console pane, from `FLASH_CONSOLE_PANE`. Claude Code only. |
| `project` | The name of the folder holding the git repository around `cwd`, or of `cwd` itself. |
| `source` | Why the session started, on `session_start` only: the agent's own word, passed on as given. Both agents document `startup`, `resume`, `clear` and `compact`; Claude Code also sends `fork`. |
| `query` | Excerpt of the prompt. |
| `response` | Excerpt of the agent's reply. |
| `summary` | Excerpt of what the agent asks for or about. |
| `tool_name` | The tool involved. |
| `tool_input` | Excerpt of the tool's input, as the JSON text the agent sent. |
| `plugin_version` | This plugin's version. |
| `error_type` | Why a turn failed, such as `rate_limit`. |
| `error_message` | Excerpt of the error text. |
| `subagent` | `true` when the hook fired for a subagent's tool or turn. |
| `active_subagents` | Optional complete list of active worker IDs in the parent conversation. An empty list clears workers; absent means unknown. Derived from Claude Stop/SubagentStop background tasks, with descriptions and commands left out. |
| `subagent_id` | The subagent's own id, when the agent's hook input names one: `agent_id`, which Claude Code and Codex send only for a hook that fires inside a subagent. Never sent for the main agent. |
| `interrupted` | `true` when the person interrupted the turn. |
| `plan` | The agent's whole to-do list, on `tool_complete` of a tool that writes or lists it: a list of steps, each `{"text": ..., "status": ...}` with `"id"` when the agent gives its steps ids. `status` is `pending`, `in_progress` or `completed`; any other is sent as `pending`. Empty when the agent cleared its list. At most 50 steps. |
| `plan_step` | One step of the plan added, changed or taken out, on `tool_complete`: `{"id": ..., "text": ..., "status": ...}`, with `text` and `status` only when they changed, and `status` `deleted` for a step taken out. |

Every text field has these characters removed: control characters, the
line and paragraph separators U+2028 and U+2029, the marks that reorder text
(U+061C, U+200E, U+200F, U+202A to U+202E, U+2066 to U+2069), and the
characters that take no space (U+200B to U+200D, U+2060 to U+2064, U+FEFF).
Excerpts (`query`, `response`, `summary`, `tool_input`, `error_message`) also
have every run of whitespace collapsed to one space, and are cut to 320
characters, ending in `…` when cut. Ids and paths are left out when too long
rather than cut; a `subagent_id` too long to send still leaves `subagent`
set. A plan's steps (`text` in `plan` and `plan_step`) are cleaned like
excerpts and cut to 160 characters. If a line would pass 8192 bytes,
excerpts shorten, then a plan's steps shorten to 80 and then 40 characters
and past the first twenty go, then excerpts go, then `project`, then `cwd`.
The ids, `source` and the flags always stay.

The plan comes from the tools each agent keeps its to-do list with, read
from a finished tool's input and output when each is at most 64 KB; the
event then carries the plan in place of the `tool_input` excerpt:

| Tool | Agent | Sends |
| :- | :- | :- |
| `TodoWrite` | Claude Code | `plan`, from `tool_input.todos` (`content`, `status`) |
| `TaskCreate` | Claude Code | `plan_step`, the new task: `tool_response.task.id`, its `subject`, `pending` |
| `TaskUpdate` | Claude Code | `plan_step`, from `tool_input` (`taskId`, `subject`, `status`); nothing when the tool answered `success: false` |
| `TaskList` | Claude Code | `plan`, from `tool_response.tasks` (`id`, `subject`, `status`) |
| `update_plan` | Codex | `plan`, from `tool_input.plan` (`step`, `status`), also when the input is JSON text |

### Events

| Event | Claude Code hook | Codex hook |
| :- | :- | :- |
| `session_start` | `SessionStart`, with `source` | `SessionStart`, with `source` |
| `prompt_submit` | `UserPromptSubmit` | `UserPromptSubmit` |
| `subagent_start` | `SubagentStart`, naming the worker | |
| `subagent_stop` | `SubagentStop`, naming the worker | |
| `tool_complete` | `PostToolUse`, `PostToolUseFailure` | `PostToolUse` |
| `permission_request` | `PermissionRequest`; `Notification` of type `permission_prompt` | `PermissionRequest` |
| `question_asked` | `PreToolUse` and `PermissionRequest` for `AskUserQuestion`; `Notification` of type `elicitation_dialog` or `elicitation_url_dialog` | `PreToolUse` for `request_user_input` |
| `stop` | `Stop`, also when `stop_hook_active` is true | `Stop`; `Interrupt`, with `interrupted: true` |
| `stop_failure` | `StopFailure`, with `error_type` and `error_message` | |
| `idle_prompt` | `Notification` of type `idle_prompt` | |

### The briefing

At a session start, after the `session_start` event, the hook connects
again and writes one request line:

```json
{"agent":"claude","cwd":"/Users/me/app","id":"9f86d081884c7d659a2feaa0c55ad015","op":"briefing","pane":"pane-42","source":"startup","v":1}
```

| Field | Meaning |
| :- | :- |
| `v` | Protocol version, `1`. |
| `op` | `briefing`. |
| `id` | 32 random hex digits, new for each request. |
| `agent` | `claude` or `codex`. |
| `cwd` | The agent's working folder, or the hook's own when the agent gave none. |
| `pane` | `FLASH_CONSOLE_PANE` for Claude Code; always empty for Codex, for the reason under [The environment Flash Console sets](#the-environment-flash-console-sets). |
| `source` | Why the session started, as on `session_start`; left out when the agent gave none. |

Flash Console answers with one line on the same connection, at most 1 MiB:

```json
{"v":1,"id":"9f86d081884c7d659a2feaa0c55ad015","ok":true,"text":"FlashTeams is available in this session..."}
```

or, when it cannot, `ok` false with a `code` and a `message`. When
FlashTeams for agents is off, or nobody is signed in, Flash Console answers
`ok` true with one short line saying so.

The hook waits at most 1.5 seconds from connecting. When the answer is a
JSON object with `v` 1, the request's `id`, `ok` true and some `text` (a
string), the hook prints exactly one line on stdout, the JSON object both
agents read from a session start hook:

```json
{"hookSpecificOutput":{"additionalContext":"FlashTeams is available in this session...","hookEventName":"SessionStart"}}
```

Before printing, the text has `\r\n` and `\r` turned into `\n`, and so do
the other line breaks (U+000B, U+000C, U+0085, U+2028 and U+2029). Every
other run of control characters but tab becomes one space, so the words
around it stay apart, and the invisible characters listed under
[Fields](#fields) go. Flash Console keeps the text under 9,000 characters.
Agents take at most 10,000 in one piece, counted as JavaScript counts a
string's length, in UTF-16 units, so a character past U+FFFF, such as most
emoji, counts as two. A longer text is cut at the end of a line and ends
with `[cut: N more characters]`.

When the answer has `v` 1 and the request's `id` but `ok` false, Flash
Console is there but could not brief this session, for example because it
was answering too many requests at once. The agent then gets a short note
in the same JSON object instead of nothing: that the briefing could not be
sent, Flash Console's `message` on one line of at most 320 characters (or
its `code` when it gave no message), and to run `flashteams tools` and
`flashteams help <tool>`.

Anything else prints nothing: no answer in time, an answer that is not one
JSON line with all of the above, or a Flash Console from before briefings,
which reads the line, finds no `event`, and closes without a word. The
starter also passes on what Perl printed only when Perl exited 0 and
printed one line that starts `{"hookSpecificOutput":{` and ends `}}`. No
other hook ever asks for a briefing, and no other hook prints anything but
the permission check's answer, below.

The longest a session start can take is a little under 3 seconds: up to
1 second waiting for the agent's input, 0.2 for the status event, 1.5 for the
briefing, and a little to finish reading the input. A hard limit of 3.3
seconds stops it, well inside the 5 seconds each agent gives the hook.

### The permission check

Claude Code only. Its `hooks.json` has a second `PreToolUse` entry, with the
matcher `Bash`, that runs `flashteams-hook.sh claude flashteams-permission`
before every Bash command. It is not an agent event: it sends Flash Console
nothing, never opens the socket, and works the same whether Flash Console is
running or not. It reads Claude Code's hook input, at most 1 MB, and when
all of these hold:

- the input is one whole JSON object with `hook_event_name` `PreToolUse`,
  `tool_name` `Bash`, and a string `tool_input.command`;
- `permission_mode` is not `plan`;
- `tool_input.dangerouslyDisableSandbox` is not true;
- the command is one plain `flashteams` command, as below,

it prints exactly this one line, and otherwise nothing:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"A flashteams command; Flash Console asks before changes that need it."}}
```

The starter passes on that line only when Perl exited 0 and printed exactly
it. With nothing printed, Claude Code's usual permission flow decides.

A plain `flashteams` command, checked strictly, so that anything the check
is unsure of gets the usual prompt:

- At most 1 MiB, with no NUL character.
- Spaces, tabs and line breaks may come before and after it; between words,
  only spaces and tabs.
- The first word is `flashteams`, unquoted, or exactly
  `$HOME/Library/Application Support/Flash Console/bin/flashteams` in single
  or double quotes, with the hook filling in `$HOME` from its own
  environment (`"$HOME/..."` written out is refused). Nothing comes before
  it: no `cd x &&`, no `VAR=value`, no `env`, `sudo` or `command`.
- Every other word is pieces written one after another: unquoted letters,
  digits and `_ . / : = @ , % + -`; a single-quoted string holding anything
  but a single quote, line breaks included; or a double-quoted string with
  no `$`, `` ` ``, `\` or `!` in it. So `--name='value'` is one word. A word
  may not start with an unquoted `=`, which zsh turns into a command's path.
- Nothing else outside quotes: no `; & | < > ( ) { } [ ] * ? ~ # ! $` or
  `` ` ``, no `\`, no line break between words, and no letter beyond ASCII,
  which also rules out lookalikes such as a full-width semicolon.
- One exception, the quoted here-document the skill uses for long text: the
  last word is `-`, then ` <<'NAME'` or ` <<"NAME"` (NAME is a letter or `_`,
  then letters, digits or `_`), then a line break, the text, a line that is
  exactly NAME, and at most one line break after it. The text can hold
  anything, because a quoted NAME stops the shell from expanding it, but no
  line of it may be exactly NAME, which would end it early and run the rest
  as commands. `<<NAME` unquoted, `<<-`, a second here-document and anything
  after the closing line are refused.

### The asks

Claude Code only, from version 1.7.0, and only in a Flash Console pane. Two
entries in its `hooks.json` wait for the person instead of reporting:

| Mode | Hook | What it asks |
| :- | :- | :- |
| `ask-permission` | a second `PermissionRequest` entry | A tool Claude Code wants to use, and from 1.9.8 Claude Code's own `AskUserQuestion` when it asks one question with two to four answers to pick one from. Several questions, or several answers to one, are left to its prompt. |
| `ask-elicitation` | `Elicitation` | An MCP server asking to go ahead, a form with no fields to fill in. A form with fields, and a request to open a web page, are left to Claude Code's prompt. |

Each has a timeout of 600 seconds, where every other hook has 5. The
starter hands an ask to Flash Console's own program, never to Perl:
`$FLASH_CONSOLE_BIN/flashteams --hook claude <mode>` on a Mac or Linux, by a
full path only, and `flashteams.exe` on Windows and inside WSL as for every
other hook. Without `FLASH_CONSOLE_PANE`, outside a Flash Console pane, the
starter does nothing at once.

The program writes one request line to Flash Console and keeps the
connection open for the answer:

```json
{"agent":"claude","args":{"detail":"rm -rf build","kind":"permission","subject":"Bash"},"cwd":"/Users/me/app","id":"9f86d081884c7d659a2feaa0c55ad015","op":"ask","pane":"pane-42","session":"s-1","v":1}
```

`args.kind` is `permission`, with the tool's name as `subject` and its
command, query, file or address as `detail`; `confirm`, with the MCP
server's name as `subject` and its message as `detail`; or `choose`, with
`AskUserQuestion` as `subject`, the question as `detail` and its answers as
`options`, each `{"label","description"}`. The program asks `choose` only
when the plugin is 1.9.8 or later, whose starter passes its answer on.
Flash Console shows the card and answers with
`{"v":1,"id":...,"ok":true,"data":{"answer":...}}`, where the answer is
`allow`, `deny` or `terminal`, or for `choose`, `choice` with the option's
place from 0 as `data.choice`. It answers `terminal` when the person
chooses Answer in the terminal, when Claude Code goes on because the person
answered in its own prompt, and after 590 seconds.

The program then prints one of these four lines, and nothing for
`terminal`, a refusal, or a Flash Console from before asks:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The person denied this in Flash Console."}}}
{"hookSpecificOutput":{"hookEventName":"Elicitation","action":"accept","content":{}}}
{"hookSpecificOutput":{"hookEventName":"Elicitation","action":"decline"}}
```

For `choose` it prints the tool allowed with its input given back on one
line, its questions first and the option picked added as `answers`, which
is how Claude Code takes an answer without its own prompt:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{"questions":[...],"answers":{"Which layout?":"One plan"}}}}}
```

The starter passes on only one of the two lines for its mode, exactly, or
for `ask-permission` a line that starts as that one does and ends with its
`answers`, and only when the program exited 0. With nothing printed, Claude Code's prompt
decides. Claude Code shows its permission prompt while the permission ask
runs and takes whichever answer comes first, so the card never holds up an
answer typed in the terminal. It runs the elicitation hook before it shows
its own prompt, so that prompt appears once the card is answered in the
terminal, or after the wait.

### Windows: flashteams.exe --hook

On Windows the starter, and Codex's `commandWindows`, run

```text
flashteams.exe --hook <agent> <hook-event>
```

with the agent's input on stdin. `<agent>` and `<hook-event>` are the words
the starter is given, `flashteams-permission` included. Flash Console's
`flashteams.exe` then does over the named pipe everything
`flashteams-hook.pl` does over the socket: the same events and fields, the
same cleaning, excerpts and 8192-byte limit, the same briefing request,
cutting at 10,000 UTF-16 units and note after a refusal, the same waits
(200 ms for a status event, 1.5 seconds for the briefing, 1.8 seconds for
the whole run, or 3.3 at a session start), and for Claude Code the same
permission check, which never opens the pipe. The full path that check
accepts is the program's own, as Windows writes it, such as
`C:\Users\me\AppData\Local\Flash Console\bin\flashteams.exe`, in place of
`$HOME/Library/...`; it holds backslashes, so only its single-quoted form
passes, as the rules above say. The program:

- exits 0 and writes nothing on stderr, whatever happens;
- prints on stdout only the one briefing object, for `SessionStart`, or
  the exact allow line above, for `flashteams-permission`, each as one line
  ended by a line feed alone, in ASCII, with every other character written
  as a `\uXXXX` escape, so that no code page and no PowerShell can change
  it;
- takes the working folder in Windows' own form, such as
  `C:\Users\me\app`, for `cwd` and `project`;
- sends as `plugin_version` the `version` in the plugin's own manifest,
  `.claude-plugin/plugin.json` or `.codex-plugin/plugin.json` in the
  folder named by `CLAUDE_PLUGIN_ROOT`, else `PLUGIN_ROOT`. Both agents set
  these for every hook (Claude Code in Git Bash writes the folder with
  slashes, such as `C:/Users/me/...`). The field is left out when the
  manifest cannot be read. On a Mac the version is the Perl program's own,
  which `test/manifests.t` keeps equal to the manifests'.

The starter in Git Bash checks the program's answer as it checks Perl's: it
passes on only one line that starts `{"hookSpecificOutput":{` and ends
`}}`, or exactly the allow line, and only when the program exited 0. Codex's
`commandWindows` passes the program's output on as it is.

`--hook` starts with a dash on purpose. A `flashteams.exe` from before
hooks takes a word that starts with a dash for a mistake and exits 2 before
it reads its input or opens the pipe, so the hook does nothing. A plain
`hook` would go to FlashTeams as the name of a tool, and the hook would
wait for an answer.

Each Windows command in Codex's `hooks.json` is one line of PowerShell, the
same for every hook but its last word, and the session start keeps stdout
for the briefing where the others discard it with `| Out-Null`:

```powershell
$d = $env:FLASH_CONSOLE_BIN; if (-not $d) { $d = $env:LOCALAPPDATA + '\Flash Console\bin' }; $f = $d + '\flashteams.exe'; if ($f -match '^[A-Za-z]:[\\/]' -and (Test-Path -LiteralPath $f -PathType Leaf -ErrorAction SilentlyContinue)) { try { & $f --hook codex Stop 2>$null | Out-Null } catch { } }; exit 0
```

### The environment Flash Console sets

Every shell Flash Console starts has `FLASH_CONSOLE_AGENT_PROTOCOL_VERSION=1`,
`FLASH_CONSOLE_VERSION`, `FLASH_CONSOLE_PANE`, the pane's stable id (not a
secret), and `FLASH_CONSOLE_BIN`, the folder that holds the `flashteams`
command, which Flash Console also adds to the end of `PATH`.

Claude Code runs its hooks inside its own process in the tab, so its events
carry `pane`. Codex runs hooks in a shared background server whose
environment belongs to whichever terminal started it, so Codex events never
carry `pane`, even when the variable is visible. Flash Console matches a
Codex event to its pane by session, working folder and timing, and drops it
when no pane is clearly right. Codex runs `SessionStart` when the first
prompt is sent, not when it launches, so a Codex `session_start` arrives just
before its first `prompt_submit`.

## The flashteams command

Flash Console provides the command and keeps it at
`~/Library/Application Support/Flash Console/bin/flashteams`, and on
Windows at `%LOCALAPPDATA%\Flash Console\bin\flashteams.exe`. It only talks
to Flash Console over the socket or named pipe above.

```sh
flashteams tools                      # every tool, one line each
flashteams help <tool>                # a tool's arguments and an example
flashteams <tool> --<argument> <value> [--json '<object>'] [--output json]
```

A value of `-` reads that argument from standard input. Flash Console
limits how long one request can be, text from standard input included, and
says so when a request is too long. Flash Console's errors are one line on
stderr. A tool turning a request down by its own rules prints its answer on
stdout as written (JSON with `"success": false`) and exits 1. The exit code
says what kind:

| Exit | Meaning |
| :- | :- |
| 0 | Done. |
| 1 | FlashTeams or the tool said no (the tool's answer is on stdout), or the person declined. |
| 2 | The command was wrong, or too long for Flash Console. |
| 3 | Flash Console is not running or is too old, or a sandbox blocked the socket. |
| 4 | FlashTeams for agents is off or read only, or nobody is signed in. |
| 5 | Timed out, busy, or the network failed. A change that timed out may still have been made, so the skill has the agent check with a read before trying again, and never ask FlashBrain the same question twice. |

Claude Code puts a plugin's `bin` folder on its Bash tool's `PATH`, so the
Claude Code plugin ships `bin/flashteams`, a short `sh` script that runs
`${FLASH_CONSOLE_BIN:-$HOME/Library/Application Support/Flash Console/bin}/flashteams`
with every argument. On Windows, where the Bash tool is Git Bash, it runs
`flashteams.exe` from `%FLASH_CONSOLE_BIN%`, else from
`%LOCALAPPDATA%\Flash Console\bin`, either written with backslashes. Git
Bash rewrites an argument that looks like a Unix path, such as
`/src/main.rs` or `--path=/src`, into a Windows path when it starts a
Windows program, so there the shim first sets `MSYS_NO_PATHCONV=1` (Git
for Windows) and `MSYS2_ARG_CONV_EXCL=*` (MSYS2), and every argument
arrives as written. A Git Bash shell that finds `flashteams.exe` on its
`PATH` directly has the same rewriting. When that file is not there it
prints
`Flash Console is not running or is too old to provide the flashteams command.`
and exits 3. Codex has no such folder, and finds the command on the `PATH`
Flash Console sets.

## What is in this repository

```text
.claude-plugin/marketplace.json     Claude Code marketplace
.agents/plugins/marketplace.json    Codex marketplace
plugins/claude/flashteams/          the Claude Code plugin
  .claude-plugin/plugin.json
  bin/flashteams                    copy of shared/bin/
  hooks/hooks.json                  which hooks run the hook program
  hooks/flashteams-hook.sh          copy of shared/hooks/
  hooks/flashteams-hook.pl          copy of shared/hooks/
  scan/flashteams-scan.pl           copy of shared/scan/, the audits' helper
  skills/flashteams/                copy of shared/skills/, plus allowed-tools
  skills/security-audit/            copies of shared/skills/
  skills/sql-audit/
  skills/architecture-review/
  skills/flash-design/
  skills/visual-qa/
  skills/roadmap/
plugins/claude/flashteams-mcp/      the optional Claude Code MCP plugin
  .claude-plugin/plugin.json
  .mcp.json                         the FlashTeams MCP server
  skills/flashteams-next-task/      copy of shared/skills/
plugins/codex/flashteams/           the Codex plugin
  .codex-plugin/plugin.json
  hooks/, scan/ and skills/         as above, without allowed-tools
plugins/codex/flashteams-mcp/       the optional Codex MCP plugin
  .codex-plugin/plugin.json
  .mcp.json and skills/             as above
shared/                             the hook program, shim, scan helper and skills, edited here
script/check                        every check, as CI runs it
script/sync                         copies shared/ into the plugins
test/                               tests: hook.t, windows.t, ask.t, bin.t, scan.t, manifests.t
```

Each plugin keeps its own copy of the shared files because each agent
installs a plugin folder on its own. Each agent's plugins are separate from
the other agent's so neither agent loads the other's manifest.

Claude Code's copy of the `flashteams` skill adds one line to the
frontmatter, `allowed-tools: Bash(flashteams:*)`, which lets every
`flashteams` command run without Claude Code asking during the turn that
loads the skill. Claude Code drops that grant at your next message, so the
permission check in `hooks/hooks.json` does the same for every later turn
(see [Permission prompts](#permission-prompts)). Flash Console asks you
before the actions that need it, and the skill tells both agents to wait
for that answer and not to try again after a no. Codex does not read
`allowed-tools`, and its plugin has no permission check; it asks before
running the command outside its sandbox.

The Codex plugins use the `.codex-plugin/plugin.json` layout on purpose.
Codex also reads a newer layout with `plugin.json` and `mcp.json` at the
plugin root, but Codex 0.160 loads only the skill and the MCP server from it
and registers none of its hooks, even with a `.codex-plugin/plugin.json`
beside it. With `.codex-plugin/plugin.json` alone, Codex loads all three, and
finds the hooks at `hooks/hooks.json`, where it looks when the manifest names
none. Do not add a root `plugin.json` to a Codex plugin; the tests fail if
one appears.

## Contributing

1. Edit the hook program, the shim, the scan helper and the skills in
   `shared/`, never the copies, then run `script/sync`.
2. Run `script/check`. It compiles the Perl, runs ShellCheck on the shell
   scripts, runs Claude Code's plugin validator when `claude` is installed,
   and runs the tests. GitHub Actions runs the same script on macOS and
   Ubuntu for every push and pull request.
3. For a release, raise `version` in all four plugin manifests
   (`plugins/claude/flashteams/.claude-plugin/plugin.json`,
   `plugins/claude/flashteams-mcp/.claude-plugin/plugin.json`,
   `plugins/codex/flashteams/.codex-plugin/plugin.json`,
   `plugins/codex/flashteams-mcp/.codex-plugin/plugin.json`) and `$VERSION`
   in `shared/hooks/flashteams-hook.pl` and `shared/scan/flashteams-scan.pl`
   together (the tests check they match). People only receive an update
   when the version changes.

The tests run the hook exactly as each agent does, with the command from its
`hooks.json`, for every event of both agents, against a throwaway socket.
They check the JSON lines, the caps, the removal of control and invisible
characters, the `subagent` and `interrupted` flags and `subagent_id`, the
plan from each agent's to-do tools and its caps, the
`source` of a session start, that Codex never sends `pane`, that nothing
reaches stdout but the briefing and the permission check's answer, the
8192-byte limit, inputs of several
megabytes, and the quiet exits: no socket, a refused socket, a socket that
never answers, a full socket queue, input that never ends, no Perl, a
missing Perl module, a hook program that does not compile, dies, fails or is
killed, a plugin folder that was deleted or lost its starter or its Perl
program, an unreadable starter, and `errexit`, `nounset` and `xtrace` passed
in through `SHELLOPTS` to bash running as `sh`.

For the briefing, the throwaway socket also stands in for Flash Console's
answer: at once, after a second, in pieces, too late, never, by closing
without a word as an older Flash Console does, and with answers that are
wrong in every way listed above. The tests check the request, the one line
printed, the text's cleaning and cutting (in UTF-16 units, with emoji), the
short note after a refusal, that nothing is printed on any other failure,
that the 1.5 second wait is honoured, that no other hook asks or prints,
and that the starter passes on nothing but one whole briefing from a Perl
program that finished well.

`test/ask.t` runs Claude Code's two asks from its `hooks.json` on a Mac, on
Windows and inside WSL, against a stand-in for Flash Console's program, and
checks that the program is started from `FLASH_CONSOLE_BIN` or
`%LOCALAPPDATA%` only in a Flash Console pane and only by a full path, with
the agent's input byte for byte; that each of the exact answers for the
mode reaches the agent, however long the person takes, and nothing else
does; and that Perl and the socket are never touched.

For Claude Code's permission check, a table of commands, some plain
`flashteams` commands and many that only look like one (chaining, pipes,
background jobs, substitution, redirections, groups, other here-documents,
something before the command, other programs and paths, open quotes,
lookalike characters, NUL, more than 1 MiB), is checked twice: against the
Perl function alone, loaded as a library, and through the hook as Claude
Code runs it. The tests also cover the input around the command (bad JSON,
other tools and events, plan mode, outside the sandbox), that the answer is
exactly one line, that nothing ever connects to the socket, that it works
without Flash Console, that the starter passes on nothing but that exact
answer, and the same quiet failures as the other hooks.

`test/windows.t` runs every hook command of both agents as Git Bash runs
it on Windows, with `OS` set to `Windows_NT`, against a stand-in
`flashteams.exe`, and checks that the stand-in is started as
`flashteams.exe --hook <agent> <hook-event>` from `FLASH_CONSOLE_BIN` or
`%LOCALAPPDATA%`, written with backslashes or a drive letter, and never
from a relative folder or another computer; that it gets the agent's
input byte for byte; that only one whole briefing or the exact allow
answer reaches the agent; that a missing, broken, killed or older program
leaves the agent nothing; that Perl and the socket are never touched; that
an agent inside WSL, where `OS` is not set, hands its hooks to the
`flashteams.exe` that `FLASH_CONSOLE_BIN` names, by a full path only, and
starts nothing without one, its permission check still answered by Perl;
that `$(exit 0)` does nothing in
`sh`, `bash`, `dash`, `zsh` and `ksh`; and the same shell options as above.
Where `pwsh` is installed, as on GitHub's runners, it also has PowerShell
parse every Windows command, runs Claude Code's commands as Claude Code
runs them without Git Bash and checks they stop at `$(exit 0)`, and runs
Codex's Windows commands with no `flashteams.exe` to find. Windows
PowerShell 5.1 and a real Git Bash need a Windows PC; see [Windows](#windows).

`test/bin.t` runs the Claude Code shim against a stand-in `flashteams`
command, on a Mac and as on Windows, and `test/manifests.t` checks both
marketplaces, all four plugins and the skills, including Claude Code's
`allowed-tools`, the permission check in Claude Code's `hooks.json`, that
Codex has none, each agent's Windows commands, and that the audit skills
and the scan helper are the same in both agents' `flashteams` plugins.

`test/scan.t` runs the audits' scan helper without the network, against
stand-ins for gitleaks, opengrep, semgrep, Trivy, curl and the `flashteams`
command that write reports shaped like the real ones, inside git
repositories it makes. It checks `doctor`'s report and install choices;
that `install` refuses Windows and a download that fails its checksum, and
the pins; that `rules` refuses a wrong checksum, another format and paths
that would leave its folder, reuses a copy it already has, and asks
FlashTeams through the `flashteams` command; each scanner's findings as one
list (categories, severities, titles, CWE), with files git ignores left
out; the SQL audit's filters; a missing scanner, semgrep in opengrep's
place, and no rules; fingerprints that stay when lines move and differ for
repeats; `show` with secrets as `[hidden]`; the payload's exact fields,
git's facts (no user name or password in the remote address, changes not
committed, a detached checkout, no commits yet), the agent's notes, the cap
of 500 findings and the summary and report caps, and that no folder of the
computer is in it; that `send` passes every field and the findings, and
passes on the command's answer and exit code; and that no secret's value
appears in any file the helper wrote or anything it printed.

You need Perl 5.20 or later to run the tests (the hook itself runs on 5.10,
the scan helper on 5.14),
bash for the shell-option tests (they are skipped without it), and
ShellCheck, which also checks each command in `hooks.json` and the guard it
runs, leaving out the `$(exit 0); ` that `test/manifests.t` checks. `pwsh`
is optional: without it the PowerShell checks are skipped.

Write comments, docs and messages in plain language, and do not use long
dashes.

## License

MIT. See [LICENSE](LICENSE).

### Worker status compatibility

Claude worker lifecycle hooks let Flash Console keep Working visible after the parent finishes responding and wait for the final worker before showing Done. Older consoles ignore the new event names and optional snapshot field. The matching console update is required to display worker activity; existing Claude sessions must restart after updating the plugin to load its new hooks. The Perl hook and the native Windows hook send the same worker IDs, with no task descriptions or command text in the snapshot.
