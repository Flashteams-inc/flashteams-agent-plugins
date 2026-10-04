#!/usr/bin/perl
# Runs the flashteams shim that the Claude Code plugin puts on the Bash
# tool's PATH, against a stand-in for the flashteams command that Flash
# Console keeps in its own folder, and checks that the shim hands over every
# argument, the input and the exit code, and that it says one plain line
# and exits 3 when Flash Console's command is not there.

use strict;
use warnings;

use Cwd qw(abs_path);
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
    my $started = time;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @{ $opt{command} || ['sh', $SHIM, @{ $opt{args} || [] }] });
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
