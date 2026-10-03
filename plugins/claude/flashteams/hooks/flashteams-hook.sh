#!/bin/sh
# Starts the FlashTeams agent hook. Each agent's hooks configuration runs
#
#   sh <plugin>/hooks/flashteams-hook.sh <agent> <hook-event>
#
# through a short guard that first checks this file is still there (see the
# README), and this passes the agent's input on to flashteams-hook.pl. It
# stays quiet and exits 0 in every case: when Flash Console is not running,
# when Perl is missing, and when anything goes wrong, even when the Perl
# program cannot compile, a module it needs is missing, or it is killed. An
# agent shows a hook that exits non-zero, or writes to stderr, as an error,
# so neither can happen here.

# Nothing printed here reaches the agent: not Perl's output, and not the
# shell's own, such as its note that Perl was killed.
exec >/dev/null 2>&1

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

command -v perl || exit 0

case $0 in
*/*) here=${0%/*} ;;
*) here=. ;;
esac

# Not exec, so that whatever Perl does, this exits 0. Perl reads the agent's
# input from the stdin it inherits.
perl "$here/flashteams-hook.pl" "$@"
exit 0
