#!/usr/bin/env perl
# Claude Code's asks, checked on this computer.
#
# Two of Claude Code's hooks wait for the person instead of reporting what
# the agent does: ask-permission, on PermissionRequest, for a tool Claude
# Code wants to use, and ask-elicitation, on Elicitation, for an MCP server
# asking to go ahead with nothing to fill in. Flash Console's own program,
# run as
#
#   flashteams --hook claude ask-permission      (flashteams.exe on Windows)
#
# shows the question as a card on the agent's pane and prints the person's
# answer. These tests run each ask's command from hooks.json against a
# stand-in for that program, on a Mac, on Windows (OS set to Windows_NT, as
# Git Bash runs it) and inside WSL in a Flash Console pane, and check that:
# the program is found only in a Flash Console pane and only by a full
# path; it gets the agent's input untouched; only one of the exact answers
# for its mode comes back, however long the person takes; and the run
# exits 0 without a word whatever happens, without starting Perl or opening
# the socket.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::UNIX;
use JSON::PP;
use POSIX qw(_exit);
use Socket qw(SOCK_STREAM);
use Test::More;
use Time::HiRes qw(time);

$SIG{PIPE} = 'IGNORE';

my $ROOT = abs_path("$FindBin::Bin/..");
my $PLUGIN = "$ROOT/plugins/claude/flashteams";
my $ALLOW = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",'
  . '"permissionDecisionReason":"A flashteams command; Flash Console asks before changes that need it."}}';

# How the answer that picks an option of Claude Code's own question starts.
my $CHOICE_START =
  '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":';

# The answers, the same text as Flash Console's program prints, by mode.
my %ANSWERS = (
    'ask-permission' => [
        '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}',
        '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny",'
          . '"message":"The person denied this in Flash Console."}}}',
        # Claude Code's own question, with the option picked.
        $CHOICE_START . '{"questions":[{"question":"Which layout?","header":"Layout","options":'
          . '[{"label":"Three tiers"},{"label":"One plan"}],"multiSelect":false}],'
          . '"answers":{"Which layout?":"One plan"}}}}}',
    ],
    'ask-elicitation' => [
        '{"hookSpecificOutput":{"hookEventName":"Elicitation","action":"accept","content":{}}}',
        '{"hookSpecificOutput":{"hookEventName":"Elicitation","action":"decline"}}',
    ],
);
my %EVENT = ('ask-permission' => 'PermissionRequest', 'ask-elicitation' => 'Elicitation');

# Unix socket paths are short, so the work happens in /tmp.
my $TMP = tempdir('ftask-XXXXXX', DIR => '/tmp', CLEANUP => 1);
make_path("$TMP/home");

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    return scalar <$fh>;
}

sub write_file {
    my ($path, $text, $mode) = @_;
    open(my $fh, '>:raw', $path) or die "$path: $!";
    print $fh $text;
    close($fh) or die "$path: $!";
    chmod($mode, $path) or die "$path: $!" if defined $mode;
    return;
}

# The ask commands from Claude Code's hooks.json, by mode, and the event
# each is registered for.
my %HANDLER;
{
    my $config = decode_json(slurp("$PLUGIN/hooks/hooks.json"));
    for my $event (sort keys %{ $config->{hooks} }) {
        for my $handler (map { @{ $_->{hooks} } } @{ $config->{hooks}{$event} }) {
            my ($name) = $handler->{command} =~ / (\S+)\z/;
            $HANDLER{$name} = { %$handler, event => $event } if $EVENT{$name};
        }
    }
}
for my $mode (sort keys %EVENT) {
    ok($HANDLER{$mode}, "Claude Code runs $mode");
    is($HANDLER{$mode}{event}, $EVENT{$mode}, "$mode runs on $EVENT{$mode}");
    cmp_ok($HANDLER{$mode}{timeout} // 0, '>=', 600, "$mode waits as long as Flash Console's card does");
}

# A stand-in for Flash Console's program. It notes the path it was started
# by, each argument on a line, and its input. Then, after STAND_IN_SLEEP
# seconds, it prints the file STAND_IN_OUTPUT names, a line on stderr, and
# exits with STAND_IN_EXIT, or kills itself with STAND_IN_SIGNAL.
my $STAND_IN = <<'EOF';
#!/bin/sh
log=${STAND_IN_LOG:?}
printf '%s\n' "$0" > "$log/program"
for arg in "$@"; do printf '%s\n' "$arg"; done > "$log/args"
cat > "$log/input"
if [ -n "${STAND_IN_SLEEP:-}" ]; then sleep "$STAND_IN_SLEEP"; fi
if [ -n "${STAND_IN_OUTPUT:-}" ]; then cat "$STAND_IN_OUTPUT"; fi
if [ -n "${STAND_IN_ERROR:-}" ]; then printf '%s\n' "$STAND_IN_ERROR" >&2; fi
if [ -n "${STAND_IN_SIGNAL:-}" ]; then kill "-$STAND_IN_SIGNAL" $$; fi
exit "${STAND_IN_EXIT:-0}"
EOF

# On a Mac, Flash Console keeps flashteams in its bin folder as a link to
# the app's own program.
my $APP = "$TMP/Flash Console.app/Contents/MacOS";
my $MAC_BIN = "$TMP/home/Library/Application Support/Flash Console/bin";
make_path($APP, $MAC_BIN);
write_file("$APP/flash-console", $STAND_IN, 0755);
symlink("$APP/flash-console", "$MAC_BIN/flashteams") or die "$MAC_BIN/flashteams: $!";

# On Windows, flashteams.exe in %LOCALAPPDATA%\Flash Console\bin, written
# with backslashes as Windows writes it.
my $LOCAL = "$TMP/Users/me/AppData/Local";
my $WIN_BIN = "$LOCAL/Flash Console/bin";
make_path($WIN_BIN);
write_file("$WIN_BIN/flashteams.exe", $STAND_IN, 0755);
(my $LOCAL_WINDOWS = $LOCAL) =~ s{/}{\\}g;

# A program in a relative folder under the agent's working folder, which
# must never run.
make_path("$TMP/relative/bin");
write_file("$TMP/relative/bin/$_", $STAND_IN, 0755) for qw(flashteams flashteams.exe);

# A perl that only notes it was started: an ask never needs it.
my $FAKE_BIN = "$TMP/fake-bin";
make_path($FAKE_BIN);
write_file("$FAKE_BIN/perl", qq{#!/bin/sh\n: > "\${STAND_IN_LOG:?}/perl"\nexit 0\n}, 0755);
my $PATH = "$FAKE_BIN:$ENV{PATH}";

# Flash Console's socket, listening, to show that an ask never connects to
# it: the program does the asking.
my $SOCKET = "$TMP/agent.sock";
my $LISTENER = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $SOCKET, Listen => 16)
  or die "cannot listen on $SOCKET: $!";
$LISTENER->blocking(0);

sub connections {
    my $n = 0;
    while (my $client = $LISTENER->accept) {
        $n++;
        close($client);
    }
    return $n;
}

# Each system as a hook sees it from a Flash Console pane, and where the
# program is found there.
my %SYSTEM = (
    mac => {
        env     => { OS => undef, FLASH_CONSOLE_BIN => $MAC_BIN },
        program => "$MAC_BIN/flashteams",
    },
    windows => {
        env     => { OS => 'Windows_NT', LOCALAPPDATA => $LOCAL_WINDOWS, FLASH_CONSOLE_BIN => undef },
        program => "$WIN_BIN/flashteams.exe",
    },
    wsl => {
        env => {
            OS                         => undef,
            WSL_DISTRO_NAME            => 'Ubuntu',
            WSL_INTEROP                => '/run/WSL/1_interop',
            FLASH_CONSOLE_AGENT_SOCKET => undef,
            FLASH_CONSOLE_BIN          => $WIN_BIN,
        },
        program => "$WIN_BIN/flashteams.exe",
    },
);

# The agent's input for each mode: one JSON object with text beyond ASCII
# and line ends of both kinds inside its strings, which the program must
# get as is.
my %INPUT = (
    'ask-permission' => qq({"session_id":"s-1","cwd":"/Users/me/app","hook_event_name":"PermissionRequest",)
      . qq("tool_name":"Bash","tool_input":{"command":"rm -rf build \xe2\x80\x94 caf\xc3\xa9\\r\\nnext"}}\n),
    'ask-elicitation' => qq({"session_id":"s-1","cwd":"/Users/me/app","hook_event_name":"Elicitation",)
      . qq("mcp_server_name":"supabase","message":"Run it on project wdvv? \xf0\x9f\x9a\x80","mode":"form",)
      . qq("requested_schema":{"type":"object","properties":{}}}\n),
);

# Runs one ask's command from hooks.json through sh, on the system given,
# in a Flash Console pane, with the environment given (undef removes a
# variable). Returns the exit status, stdout, stderr and seconds, and what
# the stand-in saw.
sub ask {
    my ($system, $mode, %opt) = @_;
    my $log = tempdir('log-XXXXXX', DIR => $TMP);
    my $io = tempdir('io-XXXXXX', DIR => $TMP);
    my %env = (
        PATH                       => $PATH,
        HOME                       => "$TMP/home",
        FLASH_CONSOLE_AGENT_SOCKET => $SOCKET,
        FLASH_CONSOLE_PANE         => 'pane-42',
        CLAUDE_PLUGIN_ROOT         => $PLUGIN,
        STAND_IN_LOG               => $log,
        %{ $SYSTEM{$system}{env} },
        %{ $opt{env} || {} },
    );
    delete $env{$_} for grep { !defined $env{$_} } keys %env;
    write_file("$io/in", $INPUT{$mode});
    connections();
    my $started = time;
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) {
        %ENV = %env;
        chdir($TMP) or _exit(97);
        open(STDIN,  '<', "$io/in")  or _exit(97);
        open(STDOUT, '>', "$io/out") or _exit(97);
        open(STDERR, '>', "$io/err") or _exit(97);
        exec { 'sh' } 'sh', '-c', $HANDLER{$mode}{command} or _exit(98);
    }
    waitpid($pid, 0);
    my $status = $? & 127 ? 'signal ' . ($? & 127) : $? >> 8;
    my $args = slurp("$log/args");
    my $program = slurp("$log/program");
    chomp($program) if defined $program;
    return {
        status      => $status,
        stdout      => slurp("$io/out") // '',
        stderr      => slurp("$io/err") // '',
        seconds     => time - $started,
        ran         => defined $args ? 1 : 0,
        program     => $program,
        args        => defined $args ? [split(/\n/, $args)] : undef,
        input       => slurp("$log/input"),
        perl        => -e "$log/perl" ? 1 : 0,
        connections => connections(),
    };
}

# Writes what the stand-in prints, and returns the variables that make it.
sub prints {
    my ($text, %more) = @_;
    my $file = File::Temp->new(DIR => $TMP, UNLINK => 0)->filename;
    write_file($file, $text);
    return { STAND_IN_OUTPUT => $file, %more };
}

# Checks a run exited 0 with nothing on stderr, never started Perl or
# connected to the socket, and printed what was expected.
sub clean {
    my ($run, $name, $stdout) = @_;
    is($run->{status}, 0, "$name: exits 0");
    is($run->{stderr}, '', "$name: nothing on stderr");
    is($run->{stdout}, $stdout // '', defined $stdout ? "$name: passes on the answer" : "$name: prints nothing");
    ok(!$run->{perl}, "$name: never starts Perl");
    is($run->{connections}, 0, "$name: never opens the socket");
    return $run;
}

for my $system (sort keys %SYSTEM) {
    for my $mode (sort keys %EVENT) {
        my $label = "$mode on $system";

        # Each answer for the mode, with or without its line end, comes
        # back as one line, and the program got the whole question.
        for my $answer (@{ $ANSWERS{$mode} }) {
            my $run = clean(ask($system, $mode, env => prints("$answer\n")), "$label, an answer", "$answer\n");
            ok($run->{ran}, "$label: runs Flash Console's program");
            is($run->{program}, $SYSTEM{$system}{program}, "$label: from the folder Flash Console keeps it in");
            is_deeply($run->{args}, ['--hook', 'claude', $mode], "$label: as --hook claude $mode");
            is($run->{input}, $INPUT{$mode}, "$label: with the agent's input, byte for byte");
            clean(ask($system, $mode, env => prints($answer)), "$label, an answer without a line end", "$answer\n");
        }

        # The person takes their time: the answer still comes back.
        my $slow = clean(ask($system, $mode, env => prints("$ANSWERS{$mode}[0]\n", STAND_IN_SLEEP => 2)),
            "$label, a slow answer", "$ANSWERS{$mode}[0]\n");
        cmp_ok($slow->{seconds}, '>=', 2, "$label, a slow answer: waited for it");

        # Anything but one exact answer for this mode leaves the question
        # to Claude Code's own prompt.
        my ($other) = grep { $_ ne $mode } sort keys %EVENT;
        my $answer = $ANSWERS{$mode}[0];
        my %refused = (
            'nothing, as when answered in the terminal' => prints(''),
            'the other ask\'s answer'                   => prints("$ANSWERS{$other}[0]\n"),
            'the permission check\'s answer'            => prints("$ALLOW\n"),
            'two answers'                               => prints("$answer\n$answer\n"),
            'a Windows line end'                        => prints("$answer\r\n"),
            'a space after'                             => prints("$answer \n"),
            'plain text'                                => prints("allow\n"),
            'an answer cut short'                       => prints(substr($answer, 0, 40)),
            'an answer, then exit 1'                    => prints("$answer\n", STAND_IN_EXIT => 1),
            'an answer, then killed'                    => prints("$answer\n", STAND_IN_SIGNAL => 'KILL'),
        );
        # An input given back is passed on only as a question's answer.
        if ($mode eq 'ask-permission') {
            my $questions = '{"questions":[{"question":"Which?","options":[{"label":"A"},{"label":"B"}]}]';
            $refused{'a command given back'} = prints($CHOICE_START . '{"command":"rm -rf build"}}}}' . "\n");
            $refused{'questions with no answer'} = prints($CHOICE_START . $questions . '}}}}' . "\n");
            $refused{'a question\'s answer over two lines'} =
              prints($CHOICE_START . $questions . "\n" . ',"answers":{"Which?":"A"}}}}}' . "\n");
            $refused{'a question\'s answer with more after it'} =
              prints($CHOICE_START . $questions . ',"answers":{"Which?":"A"}}}}} ' . "\n");
        }
        for my $case (sort keys %refused) {
            my $run = clean(ask($system, $mode, env => $refused{$case}), "$label, $case");
            ok($run->{ran}, "$label, $case: the program ran");
        }
        clean(ask($system, $mode, env => prints("$answer\n", STAND_IN_ERROR => 'a note')),
            "$label, an answer with a note on stderr", "$answer\n");

        # Outside a Flash Console pane there is no card, so nothing runs.
        for my $pane (undef, '') {
            my $where = defined $pane ? 'an empty FLASH_CONSOLE_PANE' : 'no FLASH_CONSOLE_PANE';
            my $run = clean(ask($system, $mode, env => { FLASH_CONSOLE_PANE => $pane, %{ prints("$answer\n") } }),
                "$label, $where");
            ok(!$run->{ran}, "$label, $where: runs nothing");
            cmp_ok($run->{seconds}, '<', 1, "$label, $where: quick");
        }
    }
}

# Where the program is found off Windows: FLASH_CONSOLE_BIN, by a full path
# only, so a relative folder never runs a program from the agent's working
# folder. Without it, nothing runs, though Flash Console's socket is there.
for my $system (qw(mac wsl)) {
    for my $mode (sort keys %EVENT) {
        for my $bin (undef, '', 'relative/bin', "$TMP/nowhere") {
            my $where = defined $bin ? "FLASH_CONSOLE_BIN '$bin'" : 'no FLASH_CONSOLE_BIN';
            my $run = clean(ask($system, $mode, env => { FLASH_CONSOLE_BIN => $bin, %{ prints("$ANSWERS{$mode}[0]\n") } }),
                "$mode on $system, $where");
            ok(!$run->{ran}, "$mode on $system, $where: runs nothing");
        }
    }
}

done_testing();
