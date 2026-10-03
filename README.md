# FlashTeams agent plugins

Plugins that connect Claude Code and Codex to FlashTeams. One repository
serves both: a Claude Code marketplace and a Codex marketplace, each named
`flashteams`, each with one plugin named `flashteams`.

The plugin adds three things to the agent:

- **The FlashTeams MCP server**, so the agent can find, read and update your
  FlashTeams tasks and projects. You sign in with your own FlashTeams
  account; the plugin holds no token.
- **The `flashteams-next-task` skill**, which picks up your next task, starts
  it, does the work and closes it with a plain-language handoff.
- **Agent status for Flash Console.** Small hooks tell Flash Console when the
  agent starts, is working, needs your permission or an answer, is done or
  failed, so the agent's tab shows it. They talk only to Flash Console on
  your own computer.

It works on macOS and Linux. The hooks need Perl, which comes with macOS.
Without Perl, with a Perl that cannot run them, or without Flash Console
running, they quietly do nothing.

## Install

### Claude Code

```sh
claude plugin marketplace add Flashteams-inc/flashteams-agent-plugins
claude plugin install flashteams@flashteams
```

Start a new Claude Code session, or run `/reload-plugins` in an open one.

### Codex

```sh
codex plugin marketplace add Flashteams-inc/flashteams-agent-plugins
codex plugin add flashteams@flashteams
```

Start a new Codex session. Then trust the hooks, as below.

## Sign in to FlashTeams the first time

- **Claude Code:** in a session, run `/mcp`, choose `flashteams`, then
  **Authenticate**. Your browser opens; sign in with your FlashTeams account.
- **Codex:** run `codex mcp login flashteams` and sign in in the browser.

## Trust the hooks in Codex

Codex does not run a plugin's hooks until you have looked at them. After
installing, start `codex`, run `/hooks`, review the FlashTeams hooks and
trust them. Codex asks again if an update changes them. Until then Codex
works as usual, but Flash Console does not see its status.

Claude Code needs no extra step: the hooks run once the plugin is enabled.

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

## Remove

Claude Code:

```sh
claude plugin uninstall flashteams@flashteams
claude plugin marketplace remove flashteams
```

Codex:

```sh
codex plugin remove flashteams@flashteams
codex plugin marketplace remove flashteams
```

To also sign out of FlashTeams: in Claude Code, `/mcp`, choose `flashteams`,
then **Clear authentication**; in Codex, `codex mcp logout flashteams`.

## Privacy

- The hooks send events only to Flash Console on this computer, through a
  private socket in your own user folder that only you can open. Nothing
  leaves the machine, and the hooks make no network connections.
- When Flash Console is not running, nothing is sent and nothing is kept.
- An event holds what Flash Console needs to show status: the agent, what
  happened, the session id, the working folder and its project name, the
  tool name, and short excerpts of the prompt, reply, question or tool input.
  Excerpts are at most 320 characters, on one line, with control characters
  removed.
- The hooks never print anything the agent would read, never write to your
  terminal and never slow the agent down for more than a moment.
- The MCP server is separate: the agent talks to FlashTeams with your own
  account only when it uses a FlashTeams tool.

## The protocol (version 1)

What the hooks send, for anyone building or checking the receiving side.

### Where

A Unix socket that Flash Console creates when it starts and removes when it
quits (a file left by a crash is replaced):

1. `$FLASH_CONSOLE_AGENT_SOCKET`, when it is set to an absolute path;
2. else on macOS, `$HOME/Library/Application Support/Flash Console/agent.sock`;
3. else `${XDG_RUNTIME_DIR:-$HOME/.local/state}/flash-console/agent.sock`.

The folder is mode 0700 and the socket 0600. The hook only connects to a
socket owned by the person running it.

### How

The hook connects, writes one line, a single JSON object of at most 8192
bytes ending in a newline, and closes. Flash Console does not reply. If the
socket is missing, refused or slow, the hook gives up after 200 ms and exits
0 without a word. It never writes to stdout or the terminal, never blocks the
agent, never needs `jq`, and reads at most 1 MB of the agent's hook input.

Each agent starts the hook through `flashteams-hook.sh`, which runs the Perl
program with all output discarded and then exits 0 whatever Perl did. So
when Perl cannot compile the program, lacks a module it needs, or is killed,
the agent never sees a hook error. The starter first turns off the shell
options `errexit`, `nounset` and `xtrace`, which bash takes from an exported
`SHELLOPTS`, so they cannot make it fail or print a trace.

Every command in `hooks.json` starts the starter through a short guard:

```sh
sh -c '{ set +eux; } 2>/dev/null; f=$1; shift; [ -r "$f" ] || exit 0; sh "$f" "$@" >/dev/null 2>&1; exit 0' \
  sh "${CLAUDE_PLUGIN_ROOT}/hooks/flashteams-hook.sh" claude Stop
```

Codex uses `${PLUGIN_ROOT}` in place of `${CLAUDE_PLUGIN_ROOT}`. When Codex
updates the plugin, it deletes the old plugin folder but keeps running the
hook commands it read earlier, which name files in that folder, and `sh` on a
missing file prints an error and exits non-zero. The guard exits 0 without a
word when the starter is missing or cannot be read, and discards anything
the starter prints.

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
| `interrupted` | `true` when the person interrupted the turn. |

Excerpts (`query`, `response`, `summary`, `tool_input`, `error_message`) have
every run of whitespace collapsed to one space, control characters removed,
and are cut to 320 characters, ending in `…` when cut. Ids and paths lose
control characters and are left out when too long rather than cut. If a line
would pass 8192 bytes, excerpts shorten and then go, then `project`, then
`cwd`. The ids, `source` and the flags always stay.

### Events

| Event | Claude Code hook | Codex hook |
| :- | :- | :- |
| `session_start` | `SessionStart`, with `source` | `SessionStart`, with `source` |
| `prompt_submit` | `UserPromptSubmit` | `UserPromptSubmit` |
| `tool_complete` | `PostToolUse`, `PostToolUseFailure` | `PostToolUse` |
| `permission_request` | `PermissionRequest`; `Notification` of type `permission_prompt` | `PermissionRequest` |
| `question_asked` | `PreToolUse` and `PermissionRequest` for `AskUserQuestion`; `Notification` of type `elicitation_dialog` or `elicitation_url_dialog` | `PreToolUse` for `request_user_input` |
| `stop` | `Stop`, also when `stop_hook_active` is true | `Stop`; `Interrupt`, with `interrupted: true` |
| `stop_failure` | `StopFailure`, with `error_type` and `error_message` | |
| `idle_prompt` | `Notification` of type `idle_prompt` | |

### The environment Flash Console sets

Every shell Flash Console starts has `FLASH_CONSOLE_AGENT_PROTOCOL_VERSION=1`,
`FLASH_CONSOLE_VERSION` and `FLASH_CONSOLE_PANE`, the pane's stable id (not a
secret).

Claude Code runs its hooks inside its own process in the tab, so its events
carry `pane`. Codex runs hooks in a shared background server whose
environment belongs to whichever terminal started it, so Codex events never
carry `pane`, even when the variable is visible. Flash Console matches a
Codex event to its pane by session, working folder and timing, and drops it
when no pane is clearly right. Codex runs `SessionStart` when the first
prompt is sent, not when it launches, so a Codex `session_start` arrives just
before its first `prompt_submit`.

## What is in this repository

```text
.claude-plugin/marketplace.json     Claude Code marketplace
.agents/plugins/marketplace.json    Codex marketplace
plugins/claude/flashteams/          the Claude Code plugin
  .claude-plugin/plugin.json
  .mcp.json                         the FlashTeams MCP server
  hooks/hooks.json                  which hooks run the hook program
  hooks/flashteams-hook.sh          copy of shared/hooks/
  hooks/flashteams-hook.pl          copy of shared/hooks/
  skills/flashteams-next-task/      copy of shared/skills/
plugins/codex/flashteams/           the Codex plugin
  .codex-plugin/plugin.json
  .mcp.json                         the FlashTeams MCP server
  hooks/ and skills/                as above
shared/                             the hook program and skill, edited here
script/check                        every check, as CI runs it
script/sync                         copies shared/ into both plugins
test/                               tests
```

Each plugin keeps its own copy of the shared files because each agent
installs a plugin folder on its own. The two plugin folders are separate so
neither agent loads the other's manifest.

The Codex plugin uses the `.codex-plugin/plugin.json` layout on purpose.
Codex also reads a newer layout with `plugin.json` and `mcp.json` at the
plugin root, but Codex 0.160 loads only the skill and the MCP server from it
and registers none of its hooks, even with a `.codex-plugin/plugin.json`
beside it. With `.codex-plugin/plugin.json` alone, Codex loads all three, and
finds the hooks at `hooks/hooks.json`, where it looks when the manifest names
none. Do not add a root `plugin.json` to the Codex plugin; the tests fail if
one appears.

## Contributing

1. Edit the hook program and the skill in `shared/`, never the copies, then
   run `script/sync`.
2. Run `script/check`. It compiles the Perl, runs ShellCheck on the shell
   scripts, runs Claude Code's plugin validator when `claude` is installed,
   and runs the tests. GitHub Actions runs the same script on macOS and
   Ubuntu for every push and pull request.
3. For a release, raise `version` in
   `plugins/claude/flashteams/.claude-plugin/plugin.json`,
   `plugins/codex/flashteams/.codex-plugin/plugin.json` and `$VERSION` in
   `shared/hooks/flashteams-hook.pl` together (the tests check they match).
   People only receive an update when the version changes.

The tests run the hook exactly as each agent does, with the command from its
`hooks.json`, for every event of both agents, against a throwaway socket.
They check the JSON lines, the caps, control-character removal, the
`subagent` and `interrupted` flags, the `source` of a session start, that
Codex never sends `pane`, that nothing reaches stdout, the 8192-byte limit,
inputs of several megabytes, and the quiet exits: no socket, a refused
socket, a socket that never answers, a full socket queue, input that never
ends, no Perl, a missing Perl module, a hook program that does not compile,
dies, fails or is killed, a plugin folder that was deleted or lost its
starter or its Perl program, an unreadable starter, and `errexit`, `nounset`
and `xtrace` passed in through `SHELLOPTS` to bash running as `sh`.

You need Perl 5.20 or later to run the tests (the hook itself runs on 5.10),
bash for the shell-option tests (they are skipped without it), and
ShellCheck, which also checks each command in `hooks.json` and the guard it
runs.

Write comments, docs and messages in plain language, and do not use long
dashes.

## License

MIT. See [LICENSE](LICENSE).
