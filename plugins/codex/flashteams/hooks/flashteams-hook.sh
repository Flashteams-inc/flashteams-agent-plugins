#!/bin/sh
# Starts the FlashTeams agent hook. Each agent's hooks configuration runs
#
#   sh <plugin>/hooks/flashteams-hook.sh <agent> <hook-event>
#
# and this passes the agent's input on to flashteams-hook.pl. It stays quiet
# and exits 0 in every case: when Flash Console is not running, when Perl is
# missing, and when anything goes wrong.

# Flash Console's socket, found the same way flashteams-hook.pl finds it.
# When it is not there, Flash Console is not running and there is nothing to
# do, so Perl is never started.
case ${FLASH_CONSOLE_AGENT_SOCKET:-} in
/*)
  socket=$FLASH_CONSOLE_AGENT_SOCKET
  ;;
*)
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    socket="${HOME:-}/Library/Application Support/Flash Console/agent.sock"
  else
    socket="${XDG_RUNTIME_DIR:-${HOME:-}/.local/state}/flash-console/agent.sock"
  fi
  ;;
esac
[ -S "$socket" ] || exit 0

command -v perl >/dev/null 2>&1 || exit 0

case $0 in
*/*) here=${0%/*} ;;
*) here=. ;;
esac

exec perl "$here/flashteams-hook.pl" "$@" >/dev/null 2>&1
