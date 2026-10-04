#!/usr/bin/perl
# The hooks on Windows, checked on this computer.
#
# On Windows, Flash Console's agent connection is a named pipe, which the
# Perl program cannot reach, so every hook goes to Flash Console's own
# flashteams.exe, run as
#
#   flashteams.exe --hook <agent> <hook-event>
#
# Claude Code runs its hook commands in Git Bash, and the starter hands the
# hook over. Codex runs commandWindows, one line of PowerShell, instead.
#
# These tests run each agent's commands from hooks.json as Git Bash does,
# with OS set to Windows_NT as Windows sets it for every program, against a
# stand-in for flashteams.exe, and check what the stand-in gets and what
# reaches the agent: the program is found from FLASH_CONSOLE_BIN or
# %LOCALAPPDATA%, written with Windows' backslashes, and only by a full
# path; it gets the agent's input untouched; only one whole briefing or the
# exact allow answer comes back; and the run exits 0 without a word
# whatever happens, without starting Perl or opening the socket. Claude
# Code's $(exit 0) is checked in every sh-like shell here. When pwsh is
# installed, PowerShell parses every Windows command, Claude Code's
# commands are run as Claude Code runs them without Git Bash, and Codex's
# Windows commands are run with no Flash Console to find.
#
# What only a Windows PC can show is listed in the README under Windows.

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
my %PLUGIN = (
    claude => "$ROOT/plugins/claude/flashteams",
    codex  => "$ROOT/plugins/codex/flashteams",
);
my %ROOT_VARIABLE = (claude => 'CLAUDE_PLUGIN_ROOT', codex => 'PLUGIN_ROOT');
my $PERMISSION = 'flashteams-permission';
my $POWERSHELL_EXIT = '$(exit 0); ';
my $ALLOW = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",'
  . '"permissionDecisionReason":"A flashteams command; Flash Console asks before changes that need it."}}';

# Unix socket paths are short, so the work happens in /tmp.
my $TMP = tempdir('ftwin-XXXXXX', DIR => '/tmp', CLEANUP => 1);
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

# Each agent's handlers from its hooks.json, by the last word the command
# hands the starter: the hook's own name, or flashteams-permission.
my %HANDLER;
for my $agent (sort keys %PLUGIN) {
    my $config = decode_json(slurp("$PLUGIN{$agent}/hooks/hooks.json"));
    for my $event (keys %{ $config->{hooks} }) {
        for my $handler (map { @{ $_->{hooks} } } @{ $config->{hooks}{$event} }) {
            my ($name) = $handler->{command} =~ / (\S+)\z/;
            $HANDLER{$agent}{$name} = $handler;
        }
    }
}
my %KEEPS_STDOUT = (SessionStart => 1, $PERMISSION => 1);

# A stand-in for flashteams.exe. It notes the path it was started by, each
# argument on a line, and its input, unless STAND_IN_SKIP_INPUT is set, as
# a Flash Console from before hooks refuses --hook without reading. Then it
# prints the file STAND_IN_OUTPUT names, a line on stderr, and exits with
# STAND_IN_EXIT, or kills itself with STAND_IN_SIGNAL.
my $STAND_IN = <<'EOF';
#!/bin/sh
log=${STAND_IN_LOG:?}
printf '%s\n' "$0" > "$log/program"
for arg in "$@"; do printf '%s\n' "$arg"; done > "$log/args"
if [ -z "${STAND_IN_SKIP_INPUT:-}" ]; then cat > "$log/input"; fi
if [ -n "${STAND_IN_OUTPUT:-}" ]; then cat "$STAND_IN_OUTPUT"; fi
if [ -n "${STAND_IN_ERROR:-}" ]; then printf '%s\n' "$STAND_IN_ERROR" >&2; fi
if [ -n "${STAND_IN_SIGNAL:-}" ]; then kill "-$STAND_IN_SIGNAL" $$; fi
exit "${STAND_IN_EXIT:-0}"
EOF

# %LOCALAPPDATA% as Windows writes it, with backslashes. On this computer
# the path is /tmp/..., which Git Bash would write as /c/...; the drive
# letter forms are checked further down.
my $LOCAL = "$TMP/Users/me/AppData/Local";
my $BIN = "$LOCAL/Flash Console/bin";
make_path($BIN);
write_file("$BIN/flashteams.exe", $STAND_IN, 0755);
(my $LOCAL_WINDOWS = $LOCAL) =~ s{/}{\\}g;

# A perl that only notes it was started: the Windows branch never needs it.
my $FAKE_BIN = "$TMP/fake-bin";
make_path($FAKE_BIN);
write_file("$FAKE_BIN/perl", qq{#!/bin/sh\n: > "\${STAND_IN_LOG:?}/perl"\nexit 0\n}, 0755);
my $PATH = "$FAKE_BIN:$ENV{PATH}";

# A socket where Flash Console would listen on a Mac, to show that nothing
# on Windows ever connects to one.
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

# The agent's input: one JSON object with text beyond ASCII and line ends
# of both kinds inside its strings, which flashteams.exe must get as is.
my $INPUT = qq({"session_id":"s-1","cwd":"C:\\\\Users\\\\me\\\\app","hook_event_name":"Stop",)
  . qq("prompt":"caf\xc3\xa9 \xe2\x80\x94 \xf0\x9f\x9a\x80\\r\\nnext","last_assistant_message":"done"}\n);

# Runs a command with the environment given (undef removes a variable), on
# Windows unless OS says otherwise, and the input given on stdin. Returns
# the exit status, stdout, stderr and seconds, and what the stand-in saw:
# whether it ran, the path it was started by, its arguments and its input,
# whether Perl or a noting sh started, and whether anything connected to
# the socket.
sub run {
    my (%opt) = @_;
    my $log = tempdir('log-XXXXXX', DIR => $TMP);
    my $io = tempdir('io-XXXXXX', DIR => $TMP);
    my %env = (
        PATH                       => $PATH,
        HOME                       => "$TMP/home",
        OS                         => 'Windows_NT',
        LOCALAPPDATA               => $LOCAL_WINDOWS,
        FLASH_CONSOLE_AGENT_SOCKET => $SOCKET,
        STAND_IN_LOG               => $log,
        %{ $opt{env} || {} },
    );
    delete $env{$_} for grep { !defined $env{$_} } keys %env;
    write_file("$io/in", $opt{input} // $INPUT);
    connections();
    my $started = time;
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) {
        %ENV = %env;
        chdir($opt{cwd} // $TMP) or _exit(97);
        open(STDIN,  '<', "$io/in")  or _exit(97);
        open(STDOUT, '>', "$io/out") or _exit(97);
        open(STDERR, '>', "$io/err") or _exit(97);
        exec { $opt{command}[0] } @{ $opt{command} } or _exit(98);
    }
    waitpid($pid, 0);
    my $status = $? & 127 ? 'signal ' . ($? & 127) : $? >> 8;
    my $seconds = time - $started;
    my $args = slurp("$log/args");
    my $program = slurp("$log/program");
    chomp($program) if defined $program;
    return {
        status      => $status,
        stdout      => slurp("$io/out") // '',
        stderr      => slurp("$io/err") // '',
        seconds     => $seconds,
        ran         => defined $args ? 1 : 0,
        program     => $program,
        args        => defined $args ? [split(/\n/, $args)] : undef,
        input       => slurp("$log/input"),
        perl        => -e "$log/perl" ? 1 : 0,
        sh          => -e "$log/sh" ? 1 : 0,
        connections => connections(),
    };
}

# The command an agent runs for a hook, from its hooks.json, through the
# shell given (sh unless said), with the plugin's folder in the agent's
# variable.
sub agent_run {
    my ($agent, $name, %opt) = @_;
    my $command = $HANDLER{$agent}{$name}{command};
    return run(
        %opt,
        command => [$opt{shell} // 'sh', '-c', $command],
        env     => { $ROOT_VARIABLE{$agent} => $PLUGIN{$agent}, %{ $opt{env} || {} } },
    );
}

# Checks a run exited 0 with nothing on stderr, never started Perl or
# connected to the socket, and printed what was expected.
sub clean_run {
    my ($run, $name, $stdout) = @_;
    is($run->{status}, 0, "$name: exits 0");
    is($run->{stderr}, '', "$name: nothing on stderr");
    is($run->{stdout}, $stdout // '', defined $stdout && length $stdout ? "$name: passes on the answer" : "$name: prints nothing");
    ok(!$run->{perl}, "$name: never starts Perl");
    is($run->{connections}, 0, "$name: never opens the socket");
    cmp_ok($run->{seconds}, '<', 2, "$name: quick");
    return $run;
}

# Checks the stand-in ran as flashteams.exe --hook <agent> <name> from the
# path given, and got the agent's input, byte for byte.
sub handed_over {
    my ($run, $name, $agent, $hook, $program) = @_;
    ok($run->{ran}, "$name: runs flashteams.exe");
    is($run->{program}, $program // "$BIN/flashteams.exe", "$name: from the expected folder");
    is_deeply($run->{args}, ['--hook', $agent, $hook], "$name: as flashteams.exe --hook $agent $hook");
    is($run->{input}, $INPUT, "$name: with the agent's input, byte for byte");
    return $run;
}

# Writes what the stand-in prints, and returns the variables that make it.
sub prints {
    my ($text, %more) = @_;
    my $file = File::Temp->new(DIR => $TMP, UNLINK => 0)->filename;
    write_file($file, $text);
    return { STAND_IN_OUTPUT => $file, %more };
}

my $BRIEFING = '{"hookSpecificOutput":{"additionalContext":"FlashTeams is available in this session.\nRun flashteams tools.",'
  . '"hookEventName":"SessionStart"}}';

# ---------------------------------------------------------------------------
# Every hook of both agents goes to flashteams.exe, with its input. Codex
# runs commandWindows on Windows, but its command reaches the same starter
# where Codex uses a shell like Git Bash, so it is checked too.

for my $agent (sort keys %HANDLER) {
    for my $name (sort keys %{ $HANDLER{$agent} }) {
        my $label = "$agent $name on Windows";
        # The stand-in prints something every time; only an answer the
        # starter checks may reach the agent.
        my $run = agent_run($agent, $name, env => prints("not an answer\n"));
        clean_run($run, $label);
        handed_over($run, $label, $agent, $name);
    }
}

# ---------------------------------------------------------------------------
# A session start passes on one whole briefing object and nothing else.

for my $agent (sort keys %HANDLER) {
    my $good = agent_run($agent, 'SessionStart', env => prints("$BRIEFING\n"));
    clean_run($good, "$agent briefing on Windows", "$BRIEFING\n");
    handed_over($good, "$agent briefing on Windows", $agent, 'SessionStart');

    my $unended = agent_run($agent, 'SessionStart', env => prints($BRIEFING));
    clean_run($unended, "$agent briefing without a line end", "$BRIEFING\n");

    # As long as a briefing can be once every character is a \u escape.
    my $long = '{"hookSpecificOutput":{"additionalContext":"' . ('\u00e9' x 10000) . '","hookEventName":"SessionStart"}}';
    clean_run(agent_run($agent, 'SessionStart', env => prints("$long\n")), "$agent long briefing", "$long\n");

    my %refused = (
        'two lines'                 => prints("$BRIEFING\n$BRIEFING\n"),
        'a Windows line end'        => prints("$BRIEFING\r\n"),
        'a space in front'          => prints(" $BRIEFING\n"),
        'another object'            => prints(qq({"continue":false}\n)),
        'plain text'                => prints("FlashTeams is available\n"),
        'an object cut short'       => prints(substr($BRIEFING, 0, 40)),
        'nothing'                   => prints(''),
        'a briefing, then exit 1'   => prints("$BRIEFING\n", STAND_IN_EXIT => 1),
        'a briefing, then exit 2'   => prints("$BRIEFING\n", STAND_IN_EXIT => 2),
        'a briefing, then killed'   => prints("$BRIEFING\n", STAND_IN_SIGNAL => 'KILL'),
        'a briefing and a complaint' => prints("$BRIEFING\nnot json\n", STAND_IN_ERROR => 'something broke'),
    );
    for my $case (sort keys %refused) {
        my $run = agent_run($agent, 'SessionStart', env => $refused{$case});
        clean_run($run, "$agent session start, $case");
        ok($run->{ran}, "$agent session start, $case: the program ran");
    }

    # What the program says on stderr never reaches the agent.
    clean_run(agent_run($agent, 'SessionStart', env => prints("$BRIEFING\n", STAND_IN_ERROR => 'a note')),
        "$agent briefing with a note on stderr", "$BRIEFING\n");
}

# ---------------------------------------------------------------------------
# Claude Code's permission check passes on the exact allow answer and
# nothing else.

{
    clean_run(agent_run('claude', $PERMISSION, env => prints("$ALLOW\n")), 'permission check on Windows', "$ALLOW\n");
    clean_run(agent_run('claude', $PERMISSION, env => prints($ALLOW)), 'permission check without a line end', "$ALLOW\n");
    my %refused = (
        'a Windows line end'     => prints("$ALLOW\r\n"),
        'two answers'            => prints("$ALLOW\n$ALLOW\n"),
        'a space after'          => prints("$ALLOW \n"),
        'ask instead of allow'   => prints($ALLOW =~ s/"allow"/"ask"/r),
        'the allow, then exit 1' => prints("$ALLOW\n", STAND_IN_EXIT => 1),
        'the allow, then killed' => prints("$ALLOW\n", STAND_IN_SIGNAL => 'KILL'),
        'nothing'                => prints(''),
    );
    for my $case (sort keys %refused) {
        clean_run(agent_run('claude', $PERMISSION, env => $refused{$case}), "permission check, $case");
    }
}

# ---------------------------------------------------------------------------
# Where flashteams.exe is found: FLASH_CONSOLE_BIN, which Flash Console sets
# in its shells, else %LOCALAPPDATA%\Flash Console\bin. Either may be
# written with backslashes. Only a full path counts, so a relative folder
# never runs a program from the agent's working folder.

{
    my $other = "$TMP/other/Flash Console/bin";
    make_path($other);
    write_file("$other/flashteams.exe", $STAND_IN, 0755);
    (my $other_windows = $other) =~ s{/}{\\}g;

    my $slashes = agent_run('claude', 'Stop', env => { LOCALAPPDATA => $LOCAL });
    clean_run($slashes, '%LOCALAPPDATA% with slashes');
    handed_over($slashes, '%LOCALAPPDATA% with slashes', 'claude', 'Stop');

    for my $bin ($other, $other_windows, "$other_windows\\") {
        my $run = agent_run('claude', 'Stop', env => { FLASH_CONSOLE_BIN => $bin });
        clean_run($run, "FLASH_CONSOLE_BIN $bin");
        my $program = $bin =~ /\\\z/ ? "$other//flashteams.exe" : "$other/flashteams.exe";
        handed_over($run, "FLASH_CONSOLE_BIN $bin", 'claude', 'Stop', $program);
    }

    my $empty = agent_run('claude', 'Stop', env => { FLASH_CONSOLE_BIN => '' });
    handed_over(clean_run($empty, 'FLASH_CONSOLE_BIN empty'), 'FLASH_CONSOLE_BIN empty', 'claude', 'Stop');

    # Drive letters, as Windows writes %LOCALAPPDATA%. Here C: is a folder
    # in the working folder, which only shows how the path is written: on
    # Windows, Git Bash opens C:/Users/... on drive C.
    my $cwd = "$TMP/cwd";
    for my $drive ('C:', 'd:') {
        make_path("$cwd/$drive/Users/me/AppData/Local/Flash Console/bin");
        write_file("$cwd/$drive/Users/me/AppData/Local/Flash Console/bin/flashteams.exe", $STAND_IN, 0755);
        my $run = agent_run('claude', 'Stop', cwd => $cwd, env => { LOCALAPPDATA => "$drive\\Users\\me\\AppData\\Local" });
        clean_run($run, "%LOCALAPPDATA% on drive $drive");
        handed_over($run, "%LOCALAPPDATA% on drive $drive", 'claude', 'Stop',
            "$drive/Users/me/AppData/Local/Flash Console/bin/flashteams.exe");
    }

    # A folder on another computer, \\server\share\..., which Git Bash
    # writes //server/share/..., is refused, as Codex's Windows command
    # refuses it. Here //tmp/... opens the same folder as /tmp/..., where a
    # program is waiting, so only the refusal keeps it from running.
    (my $share = $other_windows) =~ s{\A\\}{\\\\};
    (my $share_slashes = $share) =~ tr{\\}{/};
    my %elsewhere = (
        'FLASH_CONSOLE_BIN on another computer'         => { FLASH_CONSOLE_BIN => $share },
        'FLASH_CONSOLE_BIN on another computer, slashes' => { FLASH_CONSOLE_BIN => $share_slashes },
        '%LOCALAPPDATA% on another computer'            => { LOCALAPPDATA => $share =~ s{\\Flash Console\\bin\z}{}r },
    );
    ok(-x "$share_slashes/flashteams.exe", 'a program is waiting behind the //tmp/... path');
    for my $case (sort keys %elsewhere) {
        for my $name ('Stop', 'SessionStart', $PERMISSION) {
            my $run = agent_run('claude', $name, env => { %{ $elsewhere{$case} }, %{ prints("$ALLOW\n") } });
            clean_run($run, "$name, $case");
            ok(!$run->{ran}, "$name, $case: runs nothing");
        }
    }

    # Paths that are not full paths, each with a program waiting there.
    make_path("$cwd/bin", "$cwd/AppData/Local/Flash Console/bin", "$cwd/C:Users/me/Flash Console/bin");
    write_file("$cwd/bin/flashteams.exe", $STAND_IN, 0755);
    write_file("$cwd/AppData/Local/Flash Console/bin/flashteams.exe", $STAND_IN, 0755);
    write_file("$cwd/C:Users/me/Flash Console/bin/flashteams.exe", $STAND_IN, 0755);
    my %relative = (
        'a relative FLASH_CONSOLE_BIN'      => { FLASH_CONSOLE_BIN => 'bin' },
        'a relative %LOCALAPPDATA%'         => { LOCALAPPDATA => 'AppData\\Local' },
        'a drive with no folder after it'   => { LOCALAPPDATA => 'C:Users\\me' },
        'a FLASH_CONSOLE_BIN of dot'        => { FLASH_CONSOLE_BIN => '.\\bin' },
    );
    for my $case (sort keys %relative) {
        my $run = agent_run('claude', 'Stop', cwd => $cwd, env => $relative{$case});
        clean_run($run, $case);
        ok(!$run->{ran}, "$case: runs nothing");
    }

    # Nothing to run: quiet, and nothing ran.
    my $broken = "$TMP/broken";
    make_path("$broken/empty", "$broken/not-executable", "$broken/a-folder/flashteams.exe", "$broken/mac-name");
    write_file("$broken/not-executable/flashteams.exe", $STAND_IN, 0644);
    write_file("$broken/mac-name/flashteams", $STAND_IN, 0755);
    my %missing = (
        'no FLASH_CONSOLE_BIN and no %LOCALAPPDATA%' => { FLASH_CONSOLE_BIN => undef, LOCALAPPDATA => undef },
        'an empty %LOCALAPPDATA%'                    => { LOCALAPPDATA => '' },
        'Flash Console not installed'                => { LOCALAPPDATA => "$TMP/nobody" },
        'an empty folder'                            => { FLASH_CONSOLE_BIN => "$broken/empty" },
        'a program that cannot run'                  => { FLASH_CONSOLE_BIN => "$broken/not-executable" },
        'a folder in its place'                      => { FLASH_CONSOLE_BIN => "$broken/a-folder" },
        'only the Mac name, without .exe'            => { FLASH_CONSOLE_BIN => "$broken/mac-name" },
    );
    for my $case (sort keys %missing) {
        for my $name ('Stop', 'SessionStart', $PERMISSION) {
            my $run = agent_run('claude', $name, env => $missing{$case});
            clean_run($run, "$name, $case");
            ok(!$run->{ran}, "$name, $case: runs nothing");
        }
    }
}

# ---------------------------------------------------------------------------
# A Flash Console from before hooks: its flashteams.exe takes --hook for a
# misspelt tool, says so on stderr and exits 2 before reading its input.
# The agent sees nothing.

for my $name ('Stop', 'SessionStart', $PERMISSION) {
    my $run = agent_run('claude', $name, env => {
        STAND_IN_EXIT       => 2,
        STAND_IN_SKIP_INPUT => 1,
        STAND_IN_ERROR      => 'Name a tool first. Run flashteams help for how to use it.',
    });
    clean_run($run, "$name with a Flash Console from before hooks");
}

# ---------------------------------------------------------------------------
# The starter on its own, without the guard around it, as hook commands
# from before the guard ran it: it exits 0 and says nothing, whatever the
# program does.

for my $name ('Stop', 'SessionStart', $PERMISSION) {
    my %cases = (
        'a program that works'         => {},
        'a program that fails'         => { STAND_IN_EXIT => 3, STAND_IN_ERROR => 'it broke' },
        'a program that is killed'     => { STAND_IN_SIGNAL => 'KILL' },
        'a program from before hooks'  => { STAND_IN_EXIT => 2, STAND_IN_SKIP_INPUT => 1, STAND_IN_ERROR => 'Name a tool first.' },
    );
    for my $case (sort keys %cases) {
        my $run = run(command => ['sh', "$PLUGIN{claude}/hooks/flashteams-hook.sh", 'claude', $name], env => $cases{$case});
        clean_run($run, "the starter alone, $name, $case");
        ok($run->{ran}, "the starter alone, $name, $case: the program ran");
    }
}

# ---------------------------------------------------------------------------
# Not Windows: the same variables change nothing, and the hook takes the
# socket and Perl as before.

for my $os (undef, '', 'Windows', 'windows_nt', 'Darwin') {
    my $label = 'OS ' . (defined $os ? "'$os'" : 'unset');
    my $run = agent_run('claude', 'Stop', env => { OS => $os, FLASH_CONSOLE_BIN => $BIN });
    is($run->{status}, 0, "$label: exits 0");
    ok(!$run->{ran}, "$label: never runs flashteams.exe");
    ok($run->{perl}, "$label: starts Perl, as on a Mac");
}

# ---------------------------------------------------------------------------
# WSL: an agent there is a Linux program, with no OS set, even in a Flash
# Console pane on Windows. Its hooks take the Unix way and find no socket
# inside Linux, so they say nothing and never start a Windows program, even
# with Windows' variables pointing at flashteams.exe, as WSL can pass them
# on. Claude Code's permission check still runs Perl, which needs no socket.

for my $agent (sort keys %HANDLER) {
    for my $name (grep { $HANDLER{$agent}{$_} } 'Stop', 'SessionStart', $PERMISSION) {
        my $label = "$agent $name inside WSL";
        my $run = agent_run($agent, $name, env => {
            OS                         => undef,
            WSL_DISTRO_NAME            => 'Ubuntu',
            WSL_INTEROP                => '/run/WSL/1_interop',
            FLASH_CONSOLE_BIN          => $BIN,
            FLASH_CONSOLE_AGENT_SOCKET => undef,
            XDG_RUNTIME_DIR            => "$TMP/wsl-runtime",
            %{ prints("$BRIEFING\n") },
        });
        is($run->{status}, 0, "$label: exits 0");
        is($run->{stderr}, '', "$label: nothing on stderr");
        is($run->{stdout}, '', "$label: prints nothing");
        ok(!$run->{ran}, "$label: never runs flashteams.exe");
        is($run->{connections}, 0, "$label: opens no socket");
        is($run->{perl}, $name eq $PERMISSION ? 1 : 0,
            $name eq $PERMISSION ? "$label: runs the check in Perl" : "$label: never starts Perl");
    }
}

# ---------------------------------------------------------------------------
# Claude Code's $(exit 0) does nothing in a shell like sh: every sh-like
# shell here runs the rest of the command as before.

{
    my %seen;
    my @shells = grep { -x && !$seen{ abs_path($_) // $_ }++ }
      map { my $name = $_; map { "$_/$name" } split(/:/, $ENV{PATH}), '/bin' } qw(sh bash dash zsh ksh);
    ok(scalar @shells, 'there is a shell to try');
    for my $shell (@shells) {
        my $run = agent_run('claude', 'Stop', shell => $shell);
        clean_run($run, "Claude Code's command in $shell");
        handed_over($run, "Claude Code's command in $shell", 'claude', 'Stop');
        my $start = agent_run('claude', 'SessionStart', shell => $shell, env => prints("$BRIEFING\n"));
        clean_run($start, "Claude Code's session start in $shell", "$BRIEFING\n");
    }
}

# ---------------------------------------------------------------------------
# Git Bash runs sh as bash, which takes errexit, nounset and xtrace from an
# exported SHELLOPTS. With them on, the hook still exits 0, prints no
# trace, and passes on only the briefing. The agent's own shell runs the
# command without them and passes them on, as in test/hook.t.

SKIP: {
    my ($bash) = grep { -x } map { "$_/bash" } split(/:/, $ENV{PATH}), '/bin';
    skip 'bash is not installed', 1 unless $bash;
    my $bin = "$TMP/bash-as-sh";
    make_path($bin);
    symlink($bash, "$bin/sh") or die "$bin/sh: $!";
    my $path = "$bin:$PATH";
    for my $options ('errexit:xtrace', 'errexit:nounset:xtrace') {
        for my $name ('Stop', 'SessionStart', $PERMISSION) {
            my $command = $HANDLER{claude}{$name}{command};
            my ($exit, $rest) = $command =~ /\A(\Q$POWERSHELL_EXIT\E)?(.*)\z/s;
            my $output = $name eq 'Stop' ? 'noise' : $name eq 'SessionStart' ? $BRIEFING : $ALLOW;
            my $run = run(
                command => ['sh', '-c', ($exit // '') . "exec env SHELLOPTS=$options $rest"],
                env     => { PATH => $path, CLAUDE_PLUGIN_ROOT => $PLUGIN{claude}, %{ prints("$output\n") } },
            );
            clean_run($run, "$name with SHELLOPTS=$options", $name eq 'Stop' ? '' : "$output\n");
            handed_over($run, "$name with SHELLOPTS=$options", 'claude', $name);
        }
        my $none = run(command => ['sh', "$PLUGIN{claude}/hooks/flashteams-hook.sh", 'claude', 'Stop'],
            env => { PATH => $path, SHELLOPTS => $options, LOCALAPPDATA => undef, FLASH_CONSOLE_BIN => undef });
        clean_run($none, "no Flash Console with SHELLOPTS=$options");
    }
}

# ---------------------------------------------------------------------------
# Quick: the whole run, both shells and the program included.

{
    my @seconds = sort { $a <=> $b } map { agent_run('claude', 'Stop')->{seconds} } 1 .. 5;
    cmp_ok($seconds[2], '<', 0.5, 'a status hook on Windows is quick') or diag("@seconds");
}

# ---------------------------------------------------------------------------
# PowerShell, when pwsh is installed (GitHub's runners have it). Windows
# PowerShell 5.1 runs only on Windows, so these use PowerShell 7.
#
#   - Every Windows command parses.
#   - Claude Code's commands, as Claude Code runs them on a Windows PC
#     without Git Bash (in PowerShell, with ${CLAUDE_PLUGIN_ROOT} rewritten
#     to ${env:CLAUDE_PLUGIN_ROOT}), stop at $(exit 0): exit 0, nothing
#     printed, and sh never started.
#   - Codex's Windows commands, run as Codex runs them, exit 0 without a
#     word when there is no flashteams.exe to find. Off Windows a folder
#     has no drive letter, so they never find one here.

SKIP: {
    my ($pwsh) = grep { -x } map { "$_/pwsh" } split(/:/, $ENV{PATH});
    skip 'pwsh is not installed, so PowerShell was not checked', 1 unless $pwsh;

    my $sh_bin = "$TMP/sh-that-notes";
    make_path($sh_bin);
    write_file("$sh_bin/sh", qq{#!/bin/sh\n: > "\${STAND_IN_LOG:?}/sh"\nexit 0\n}, 0755);

    my @claude = map { $HANDLER{claude}{$_}{command} } sort keys %{ $HANDLER{claude} };
    my @codex = map { $HANDLER{codex}{$_}{commandWindows} } sort keys %{ $HANDLER{codex} };
    my @rewritten = map { s/\$\{CLAUDE_PLUGIN_ROOT\}/\${env:CLAUDE_PLUGIN_ROOT}/gr } @claude;

    # Parsing: one pwsh, every command, each parse error named.
    my $parse = run(
        command => [$pwsh, '-NoProfile', '-NonInteractive', '-Command',
            '$all = $env:FT_COMMANDS | ConvertFrom-Json; foreach ($c in $all) { $t = $null; $e = $null; '
              . '$null = [System.Management.Automation.Language.Parser]::ParseInput($c, [ref]$t, [ref]$e); '
              . 'foreach ($x in $e) { Write-Output ($x.Message + \' | \' + $c) } }; exit 0'],
        env => { OS => undef, FT_COMMANDS => JSON::PP->new->ascii->encode([@rewritten, @codex]) },
    );
    is($parse->{status}, 0, 'pwsh parsed the commands');
    is($parse->{stdout}, '', 'every Windows command parses in PowerShell') or diag($parse->{stdout});

    my %powershell_env = (OS => undef, PATH => "$sh_bin:$ENV{PATH}", CLAUDE_PLUGIN_ROOT => $PLUGIN{claude});
    for my $i (0 .. $#rewritten) {
        my ($name) = $rewritten[$i] =~ / (\S+)\z/;
        my $run = run(command => [$pwsh, '-NoProfile', '-NonInteractive', '-Command', $rewritten[$i]],
            env => \%powershell_env);
        is($run->{status}, 0, "PowerShell: Claude Code's $name exits 0");
        is($run->{stdout}, '', "PowerShell: Claude Code's $name prints nothing");
        is($run->{stderr}, '', "PowerShell: Claude Code's $name says nothing on stderr");
        ok(!$run->{sh}, "PowerShell: Claude Code's $name stops before sh");
    }
    my %codex_env = (OS => undef, LOCALAPPDATA => undef, FLASH_CONSOLE_BIN => undef);
    for my $command (@codex) {
        my ($name) = $command =~ /--hook codex (\S+)/;
        for my $case (['nothing set', {}], ['FLASH_CONSOLE_BIN with no drive', { FLASH_CONSOLE_BIN => $BIN }],
            ['%LOCALAPPDATA% with no drive', { LOCALAPPDATA => $LOCAL_WINDOWS }])
        {
            my ($what, $env) = @$case;
            my $run = run(command => [$pwsh, '-NoProfile', '-Command', $command], env => { %codex_env, %$env });
            is($run->{status}, 0, "PowerShell: Codex's $name, $what: exits 0");
            is($run->{stdout}, '', "PowerShell: Codex's $name, $what: prints nothing");
            is($run->{stderr}, '', "PowerShell: Codex's $name, $what: says nothing on stderr");
            ok(!$run->{ran}, "PowerShell: Codex's $name, $what: runs nothing");
        }
    }
}

done_testing();
