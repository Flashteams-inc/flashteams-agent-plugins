#!/bin/sh
# Starts the FlashTeams agent hook. Each agent's hooks configuration runs
#
#   sh <plugin>/hooks/flashteams-hook.sh <agent> <hook-event>
#
# through a short guard that first checks this file is still there (see the
# README). On macOS and Linux this passes the agent's input on to
# flashteams-hook.pl. On Windows, where Claude Code runs it in Git Bash, it
# passes the input on to Flash Console's own flashteams.exe instead, as
#
#   flashteams.exe --hook <agent> <hook-event>
#
# It exits 0 in every case: when Flash Console is not running or not
# installed, when Perl is missing, and when anything goes wrong, even when
# the Perl program cannot compile, a module it needs is missing, or it is
# killed. An agent shows a hook that exits non-zero, or writes to stderr, as
# an error, so neither can happen here.
#
# Only two hooks ever print anything, and only on stdout: a session start,
# the one JSON object that hands the agent its FlashTeams briefing from
# Flash Console, and Claude Code's permission check (flashteams-permission),
# the one JSON object that lets a plain flashteams command run without
# Claude Code's prompt. Every other hook prints nothing at all.

# The shell may start with options already on, such as errexit or xtrace
# from a SHELLOPTS that bash reads at start. They could make this stop early
# with a failure, or print a trace, so they are turned off before anything
# else, out of sight of xtrace.
{ set +eux; } 2>/dev/null

# Nothing else printed here reaches the agent: not Perl's output, and not
# the shell's own, such as its note that Perl was killed. A session start
# and the permission check keep stdout for their answer, which is checked
# before it is passed on.
case ${2-} in
SessionStart | flashteams-permission) exec 2>/dev/null ;;
*) exec >/dev/null 2>&1 ;;
esac

# The permission check's one answer, the same text as $ALLOW in
# flashteams-hook.pl, and the same that flashteams.exe prints on Windows.
allow='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"A flashteams command; Flash Console asks before changes that need it."}}'

# Windows sets OS to Windows_NT for every program. There the Perl program
# cannot reach Flash Console, whose agent connection is a named pipe, so
# Flash Console's own flashteams.exe does the whole hook: the status event,
# the briefing and the permission check. It is found in FLASH_CONSOLE_BIN,
# which Flash Console sets in every shell it starts, else in the folder
# Flash Console keeps it in, %LOCALAPPDATA%\Flash Console\bin. Without it,
# Flash Console is not installed and there is nothing to do. Its answers are
# checked exactly as Perl's are below.
if [ "${OS-}" = Windows_NT ]; then
  dir=${FLASH_CONSOLE_BIN:-}
  if [ -z "$dir" ]; then
    [ -n "${LOCALAPPDATA:-}" ] || exit 0
    dir="$LOCALAPPDATA/Flash Console/bin"
  fi
  # Windows writes its paths with backslashes, and Git Bash takes slashes.
  rest="$dir/flashteams.exe"
  program=
  while :; do
    case $rest in
    *\\*)
      program="$program${rest%%\\*}/"
      rest=${rest#*\\}
      ;;
    *)
      program="$program$rest"
      break
      ;;
    esac
  done
  # Only a full path on this PC, such as C:/Users/me/... or /c/Users/me/...,
  # so a relative folder never runs a program from the agent's working
  # folder. A path on another computer, \\server\share\... (here
  # //server/share/...), is refused too, as Codex's Windows command refuses
  # it: Flash Console keeps the program on this PC, and a share that stops
  # answering would hold up every hook.
  case $program in
  //*) exit 0 ;;
  [A-Za-z]:/* | /*) ;;
  *) exit 0 ;;
  esac
  [ -f "$program" ] || exit 0
  [ -x "$program" ] || exit 0

  # Not exec, so that whatever the program does, this exits 0. It reads
  # the agent's input from the stdin it inherits. A Flash Console from
  # before hooks refuses --hook with exit 2 before reading anything.
  case ${2-} in
  SessionStart)
    answer=$("$program" --hook "$@") || exit 0
    case $answer in
    *'
'*) ;;
    '{"hookSpecificOutput":{'*'}}') printf '%s\n' "$answer" ;;
    esac
    ;;
  flashteams-permission)
    answer=$("$program" --hook "$@") || exit 0
    if [ "$answer" = "$allow" ]; then
      printf '%s\n' "$answer"
    fi
    ;;
  *)
    "$program" --hook "$@"
    ;;
  esac
  exit 0
fi

case $0 in
*/*) here=${0%/*} ;;
*) here=. ;;
esac

# The permission check needs nothing but the agent's input, so it runs
# whether or not Flash Console is running, and never uses its socket. Its
# answer is passed on only when Perl finished well and printed exactly the
# answer that allows the command, so anything else leaves Claude Code to ask
# as usual.
if [ "${2-}" = flashteams-permission ]; then
  command -v perl >/dev/null || exit 0
  answer=$(perl "$here/flashteams-hook.pl" "$@") || exit 0
  if [ "$answer" = "$allow" ]; then
    printf '%s\n' "$answer"
  fi
  exit 0
fi

# Flash Console's socket, found the same way flashteams-hook.pl finds it.
# When it is not there, Flash Console is not running and there is nothing to
# do, so Perl is never started.
case ${FLASH_CONSOLE_AGENT_SOCKET:-} in
/*)
  socket=$FLASH_CONSOLE_AGENT_SOCKET
  ;;
*)
  if [ "$(uname -s)" = Darwin ]; then
    socket="${HOME:-}/Library/Application Support/Flash Console/agent.sock"
  else
    socket="${XDG_RUNTIME_DIR:-${HOME:-}/.local/state}/flash-console/agent.sock"
  fi
  ;;
esac
[ -S "$socket" ] || exit 0

command -v perl >/dev/null || exit 0

# Not exec, so that whatever Perl does, this exits 0. Perl reads the agent's
# input from the stdin it inherits.
if [ "${2-}" = SessionStart ]; then
  # The briefing is passed on only when Perl finished well and printed one
  # whole briefing object on one line, so a Perl program that fails, is
  # killed half way or prints anything else leaves the agent nothing to
  # read.
  answer=$(perl "$here/flashteams-hook.pl" "$@") || exit 0
  case $answer in
  *'
'*) ;;
  '{"hookSpecificOutput":{'*'}}') printf '%s\n' "$answer" ;;
  esac
  exit 0
fi
perl "$here/flashteams-hook.pl" "$@"
exit 0
