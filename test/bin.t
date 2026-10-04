#!/usr/bin/perl
# Runs the flashteams shim that the Claude Code plugin puts on the Bash
# tool's PATH, against a stand-in for the flashteams command that Flash
# Console keeps in its own folder, and checks that the shim hands over every
# argument, the input and the exit code, and that it says one plain line
# and exits 3 when Flash Console's command is not there. On Windows the
# command is flashteams.exe, found from FLASH_CONSOLE_BIN or %LOCALAPPDATA%,
# either of which may be written with backslashes.

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;
use Time::HiRes qw(time);

my $ROOT = abs_path("$FindBin::Bin/..");
my $SHIM = "$ROOT/plugins/claude/flashteams/bin/flashteams";
my $TMP = tempdir('ftbin-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $MISSING = "Flash Console is not running or is too old to provide the flashteams command.\n";

sub write_file {
    my ($path, $text, $mode) = @_;
    open(my $fh, '>', $path) or die "$path: $!";
    print $fh $text;
    close($fh) or die "$path: $!";
    chmod($mode, $path) or die "$path: $!" if defined $mode;
    return;
}

# Runs a command with exactly the environment given (undef removes a
# variable) and the input given. Returns the exit status, stdout, stderr and
# how long it ran.
sub run {
    my (%opt) = @_;
    my %env = (PATH => $ENV{PATH}, HOME => "$TMP/home", %{ $opt{env} || {} });
    delete $env{$_} for grep { !defined $env{$_} } keys %env;
    local %ENV = %env;
    my $here = getcwd();
    chdir($opt{cwd}) or die "$opt{cwd}: $!" if defined $opt{cwd};
    my $started = time;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @{ $opt{command} || ['sh', $SHIM, @{ $opt{args} || [] }] });
    chdir($here) or die "$here: $!";
    print $in $opt{input} if defined $opt{input};
    close($in);
    my $stdout = do { local $/; <$out> } // '';
    my $stderr = do { local $/; <$err> } // '';
    waitpid($pid, 0);
    return {
        status  => $? & 127 ? 'signal ' . ($? & 127) : $? >> 8,
        stdout  => $stdout,
        stderr  => $stderr,
        seconds => time - $started,
    };
}

# A stand-in for Flash Console's flashteams command: it prints each argument
# on a line of its own, then its input, notes the variable that marks the
# shim, and exits with the code in STAND_IN_EXIT.
my $STAND_IN = <<'EOF';
#!/bin/sh
for arg in "$@"; do printf '[%s]\n' "$arg"; done
printf 'input:%s\n' "$(cat)"
printf 'via shim:%s\n' "${FLASHTEAMS_SHIM:-}"
echo "a note on stderr" >&2
exit "${STAND_IN_EXIT:-0}"
EOF

my $BIN = "$TMP/flash-console-bin";
make_path($BIN);
write_file("$BIN/flashteams", $STAND_IN, 0755);

ok(-x $SHIM, 'the shim is executable');

# Every argument, the input, the output and the exit code pass through.
{
    my @args = ('update_task', '--task_id', 'abc', '--closing_note', '-', '', 'two words', '--json={"a": 1}', '*');
    my $run = run(args => \@args, env => { FLASH_CONSOLE_BIN => $BIN, STAND_IN_EXIT => 4 },
        input => "What I did.\nWhat is left.");
    is($run->{status}, 4, 'the exit code passes through');
    is($run->{stdout}, join('', map { "[$_]\n" } @args) . "input:What I did.\nWhat is left.\nvia shim:1\n",
        'every argument, as given, and the input pass through');
    is($run->{stderr}, "a note on stderr\n", 'stderr passes through');

    for my $code (0, 1, 2, 3, 5) {
        my $each = run(args => ['tools'], env => { FLASH_CONSOLE_BIN => $BIN, STAND_IN_EXIT => $code });
        is($each->{status}, $code, "exit code $code passes through");
    }

    my $none = run(env => { FLASH_CONSOLE_BIN => $BIN });
    is($none->{status}, 0, 'no arguments: the command runs');
    is($none->{stdout}, "input:\nvia shim:1\n", 'no arguments: none are made up');
}

# Found through the PATH, as Claude Code's Bash tool finds it.
{
    my $run = run(command => ['sh', '-c', 'flashteams tools'],
        env => { PATH => "$ROOT/plugins/claude/flashteams/bin:$ENV{PATH}", FLASH_CONSOLE_BIN => $BIN });
    is($run->{status}, 0, 'through the PATH: runs');
    like($run->{stdout}, qr/\A\[tools\]\n/, 'through the PATH: reaches Flash Console\'s command');
}

# Without FLASH_CONSOLE_BIN, or with it empty, the shim looks where Flash
# Console keeps the command on macOS.
{
    my $home = "$TMP/home";
    my $default = "$home/Library/Application Support/Flash Console/bin";
    make_path($default);
    # Flash Console keeps the command as a link to its own program.
    symlink("$BIN/flashteams", "$default/flashteams") or die $!;
    for my $value (undef, '') {
        my $label = defined $value ? 'empty' : 'unset';
        my $run = run(args => ['help'], env => { FLASH_CONSOLE_BIN => $value, HOME => $home });
        is($run->{status}, 0, "FLASH_CONSOLE_BIN $label: runs the command in Flash Console's folder");
        like($run->{stdout}, qr/\A\[help\]\n/, "FLASH_CONSOLE_BIN $label: hands over the arguments");
    }
}

# No command to hand over to: one plain line on stderr, nothing on stdout,
# exit 3.
{
    my $broken = "$TMP/broken";
    make_path("$broken/not-executable", "$broken/a-folder/flashteams", "$broken/dangling");
    write_file("$broken/not-executable/flashteams", $STAND_IN, 0644);
    symlink("$TMP/nowhere/flashteams", "$broken/dangling/flashteams") or die $!;
    my %cases = (
        'no such folder'              => { FLASH_CONSOLE_BIN => "$TMP/missing" },
        'an empty folder'             => { FLASH_CONSOLE_BIN => "$broken" },
        'a command that cannot run'   => { FLASH_CONSOLE_BIN => "$broken/not-executable" },
        'a folder in its place'       => { FLASH_CONSOLE_BIN => "$broken/a-folder" },
        'a link to nothing'           => { FLASH_CONSOLE_BIN => "$broken/dangling" },
        'no Flash Console folder'     => { FLASH_CONSOLE_BIN => undef, HOME => "$TMP/empty-home" },
        'no home folder'              => { FLASH_CONSOLE_BIN => undef, HOME => undef },
        # A FLASH_CONSOLE_BIN naming the plugin's own folder would start the
        # shim again and again.
        'the shim\'s own folder'      => { FLASH_CONSOLE_BIN => "$ROOT/plugins/claude/flashteams/bin" },
    );
    for my $name (sort keys %cases) {
        my $run = run(args => ['tools'], env => $cases{$name});
        is($run->{status}, 3, "$name: exits 3");
        is($run->{stdout}, '', "$name: nothing on stdout");
        is($run->{stderr}, $MISSING, "$name: says Flash Console is not running or is too old");
        cmp_ok($run->{seconds}, '<', 2, "$name: quick");
    }
}

# On Windows, where Claude Code's Bash tool is Git Bash, the command is
# flashteams.exe, in FLASH_CONSOLE_BIN, else in
# %LOCALAPPDATA%\Flash Console\bin, either written with Windows'
# backslashes. Windows sets OS to Windows_NT for every program.
{
    my $local = "$TMP/win/Users/me/AppData/Local";
    my $bin = "$local/Flash Console/bin";
    make_path($bin);
    write_file("$bin/flashteams.exe", $STAND_IN, 0755);
    (my $local_windows = $local) =~ s{/}{\\}g;
    my %windows = (OS => 'Windows_NT', FLASH_CONSOLE_BIN => undef, LOCALAPPDATA => $local_windows);

    my @args = ('update_task', '--task_id', 'abc', '--closing_note', '-', '', 'two words', 'C:\\Users\\me', '*');
    my $run = run(args => \@args, env => { %windows, STAND_IN_EXIT => 4 }, input => "caf\xc3\xa9\r\nWhat is left.");
    is($run->{status}, 4, 'Windows: the exit code passes through');
    is($run->{stdout}, join('', map { "[$_]\n" } @args) . "input:caf\xc3\xa9\r\nWhat is left.\nvia shim:1\n",
        'Windows: every argument, as given, and the input pass through');
    is($run->{stderr}, "a note on stderr\n", 'Windows: stderr passes through');

    # FLASH_CONSOLE_BIN first, with backslashes or slashes, then
    # %LOCALAPPDATA%; a FLASH_CONSOLE_BIN that is empty counts as unset.
    my $other = "$TMP/win/other";
    make_path($other);
    write_file("$other/flashteams.exe", "#!/bin/sh\necho other\n", 0755);
    (my $other_windows = $other) =~ s{/}{\\}g;
    for my $value ($other, $other_windows) {
        my $first = run(args => ['tools'], env => { %windows, FLASH_CONSOLE_BIN => $value });
        is($first->{stdout}, "other\n", "Windows: FLASH_CONSOLE_BIN $value comes first");
    }
    my $empty = run(args => ['tools'], env => { %windows, FLASH_CONSOLE_BIN => '' });
    like($empty->{stdout}, qr/\A\[tools\]\n/, 'Windows: an empty FLASH_CONSOLE_BIN leaves %LOCALAPPDATA%');

    # A drive letter, as Windows writes %LOCALAPPDATA%. Here C: is a folder
    # in the working folder, which only shows how the path is written.
    my $cwd = "$TMP/win/cwd";
    make_path("$cwd/C:/Users/me/AppData/Local/Flash Console/bin");
    write_file("$cwd/C:/Users/me/AppData/Local/Flash Console/bin/flashteams.exe", $STAND_IN, 0755);
    my $drive = run(args => ['tools'], cwd => $cwd, env => { %windows, LOCALAPPDATA => 'C:\\Users\\me\\AppData\\Local' });
    is($drive->{status}, 0, 'Windows: %LOCALAPPDATA% on drive C: runs');
    like($drive->{stdout}, qr/\A\[tools\]\n/, 'Windows: %LOCALAPPDATA% on drive C: hands over the arguments');

    # Found through the PATH, as Claude Code's Bash tool finds it.
    my $path = run(command => ['sh', '-c', 'flashteams tools'],
        env => { %windows, PATH => "$ROOT/plugins/claude/flashteams/bin:$ENV{PATH}" });
    is($path->{status}, 0, 'Windows: through the PATH: runs');
    like($path->{stdout}, qr/\A\[tools\]\n/, 'Windows: through the PATH: reaches flashteams.exe');

    # No command to hand over to: the one plain line, exit 3.
    my $broken = "$TMP/win/broken";
    make_path("$broken/mac-name", "$broken/not-executable", "$broken/a-folder/flashteams.exe");
    write_file("$broken/mac-name/flashteams", $STAND_IN, 0755);
    write_file("$broken/not-executable/flashteams.exe", $STAND_IN, 0644);
    my %cases = (
        'no FLASH_CONSOLE_BIN and no %LOCALAPPDATA%' => { LOCALAPPDATA => undef },
        'Flash Console not installed'                => { LOCALAPPDATA => "$TMP\\nobody" },
        'only the Mac name, without .exe'            => { FLASH_CONSOLE_BIN => "$broken/mac-name" },
        'a command that cannot run'                  => { FLASH_CONSOLE_BIN => "$broken/not-executable" },
        'a folder in its place'                      => { FLASH_CONSOLE_BIN => "$broken/a-folder" },
        'the shim\'s own folder'                     => { FLASH_CONSOLE_BIN => "$ROOT/plugins/claude/flashteams/bin" },
        'the shim started by itself'                 => { FLASHTEAMS_SHIM => 1 },
    );
    for my $name (sort keys %cases) {
        my $missing = run(args => ['tools'], env => { %windows, %{ $cases{$name} } });
        is($missing->{status}, 3, "Windows, $name: exits 3");
        is($missing->{stdout}, '', "Windows, $name: nothing on stdout");
        is($missing->{stderr}, $MISSING, "Windows, $name: says Flash Console is not running or is too old");
    }

    # Not Windows: %LOCALAPPDATA% means nothing, and the Mac folder is used.
    my $mac = run(args => ['tools'], env => { %windows, OS => undef, HOME => "$TMP/empty-home" });
    is($mac->{status}, 3, 'not Windows: %LOCALAPPDATA% is not used');

    # Git Bash rewrites an argument that looks like a Unix path when it
    # starts a Windows program, so /src/main.rs would reach flashteams.exe
    # as C:/Program Files/Git/src/main.rs. On Windows the shim turns that
    # off for Git for Windows and for MSYS2; on a Mac it sets neither.
    my $conversion = "$TMP/win/conversion";
    make_path($conversion);
    write_file("$conversion/flashteams.exe", <<'EOF', 0755);
#!/bin/sh
printf 'MSYS_NO_PATHCONV=[%s]\n' "${MSYS_NO_PATHCONV-unset}"
printf 'MSYS2_ARG_CONV_EXCL=[%s]\n' "${MSYS2_ARG_CONV_EXCL-unset}"
for arg in "$@"; do printf '[%s]\n' "$arg"; done
EOF
    symlink("$conversion/flashteams.exe", "$conversion/flashteams") or die $!;
    my @paths = ('read_source', '--path', '/src/main.rs', '--path=/src', '/a:/b');
    my $off = run(args => \@paths, env => { %windows, FLASH_CONSOLE_BIN => $conversion });
    is($off->{status}, 0, 'Windows: a Unix-looking argument: runs');
    is($off->{stdout}, "MSYS_NO_PATHCONV=[1]\nMSYS2_ARG_CONV_EXCL=[*]\n" . join('', map { "[$_]\n" } @paths),
        'Windows: Git Bash is told not to rewrite arguments that look like Unix paths');
    my $kept = run(args => \@paths, env => { %windows, OS => undef, FLASH_CONSOLE_BIN => $conversion });
    is($kept->{stdout}, "MSYS_NO_PATHCONV=[unset]\nMSYS2_ARG_CONV_EXCL=[unset]\n" . join('', map { "[$_]\n" } @paths),
        'not Windows: the shim sets neither');
}

# Shell options from an exported SHELLOPTS change nothing. bash takes them
# also when it runs as sh.
SKIP: {
    my ($bash) = grep { -x } map { "$_/bash" } split(/:/, $ENV{PATH}), '/bin';
    skip 'bash is not installed', 1 unless $bash;
    my $bin = "$TMP/bash-as-sh";
    make_path($bin);
    symlink($bash, "$bin/sh") or die "$bin/sh: $!";
    my %env = (PATH => "$bin:$ENV{PATH}", SHELLOPTS => 'errexit:nounset');
    my $run = run(args => ['tools'], env => { %env, FLASH_CONSOLE_BIN => $BIN });
    is($run->{status}, 0, 'with errexit and nounset: runs');
    like($run->{stdout}, qr/\A\[tools\]\n/, 'with errexit and nounset: hands over the arguments');
    my $none = run(env => { %env, FLASH_CONSOLE_BIN => $BIN });
    is($none->{status}, 0, 'with nounset and no arguments: runs');
    my $missing = run(args => ['tools'], env => { %env, FLASH_CONSOLE_BIN => undef, HOME => undef });
    is($missing->{status}, 3, 'with nounset and no home folder: exits 3');
    is($missing->{stderr}, $MISSING, 'with nounset and no home folder: the one plain line');
}

done_testing();
