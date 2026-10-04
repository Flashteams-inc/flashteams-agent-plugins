#!/bin/sh
# Starts the FlashTeams agent hook. Each agent's hooks configuration runs
#
#   sh <plugin>/hooks/flashteams-hook.sh <agent> <hook-event>
#
# through a short guard that first checks this file is still there (see the
# README), and this passes the agent's input on to flashteams-hook.pl. It
# exits 0 in every case: when Flash Console is not running, when Perl is
# missing, and when anything goes wrong, even when the Perl program cannot
# compile, a module it needs is missing, or it is killed. An agent shows a
# hook that exits non-zero, or writes to stderr, as an error, so neither can
# happen here.
#
# Only a session start ever prints anything, and only on stdout: the one
# JSON object that hands the agent its FlashTeams briefing from Flash
# Console. Every other hook prints nothing at all.

# The shell may start with options already on, such as errexit or xtrace
# from a SHELLOPTS that bash reads at start. They could make this stop early
# with a failure, or print a trace, so they are turned off before anything
# else, out of sight of xtrace.
{ set +eux; } 2>/dev/null

# Nothing else printed here reaches the agent: not Perl's output, and not
# the shell's own, such as its note that Perl was killed. A session start
# keeps stdout for the briefing, which is checked before it is passed on.
if [ "${2-}" = SessionStart ]; then
  exec 2>/dev/null
else
  exec >/dev/null 2>&1
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

case $0 in
*/*) here=${0%/*} ;;
*) here=. ;;
esac

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
