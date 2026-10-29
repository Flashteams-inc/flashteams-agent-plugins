#!/usr/bin/perl
# FlashTeams scan helper. The security-audit, sql-audit and
# architecture-review skills run it to scan a repository on this computer
# and to build the scan they record in FlashTeams.
#
#   perl flashteams-scan.pl doctor [--json]
#   perl flashteams-scan.pl install <tool>...
#   perl flashteams-scan.pl rules [--url <url> --sha256 <hex>] [--dir <cache>]
#   perl flashteams-scan.pl run --kind security|sql [--mode quick|full]
#       [--path <folder>] [--rules <folder>] [--out <work folder>]
#   perl flashteams-scan.pl show --out <work folder> --ids 3,12,40
#   perl flashteams-scan.pl payload --out <work folder>
#       --kind security|sql|architecture [--mode quick|full] [--path <folder>]
#       --summary-file <file> --report-file <file> [--notes <file>]
#   perl flashteams-scan.pl send --out <work folder> [--product-id <id>]
#       [--organization-id <id>]
#
# The scanners are gitleaks (secrets), opengrep (FlashTeams' code rules;
# semgrep in its place when opengrep is not installed) and Trivy
# (infrastructure files, and dependency vulnerabilities in full mode).
# install downloads the versions FlashTeams' own scanner uses, checked
# against pinned checksums, into a folder of their own.
#
# Rules this program keeps, whatever happens:
#   - a secret's value is never printed or written: gitleaks runs with
#     --redact, its Secret, Match and Line fields are dropped as they are
#     read, the line text of a secret is never kept, and show prints
#     [hidden] in its place;
#   - the scanners' own reports, which quote the code, are deleted once
#     read; the work folder keeps only scan.json, tools.json,
#     findings.json, hidden.json and payload.json, which hold no code;
#   - only send sends anything, and only to Flash Console, through the
#     flashteams command: the payload, which the agent built and can read
#     first. It downloads only when told to: install and rules fetch with
#     curl (rules asks FlashTeams for the address through the flashteams
#     command), and a full scan lets Trivy fetch its vulnerability
#     database. Trivy runs with its usage data turned off;
#   - the payload holds no folder of this computer and no user name;
#   - it needs Perl and the modules that ship with it, git, and curl for
#     downloads. Nothing else.
#
# FLASHTEAMS_TOOLS_DIR (default ~/.flashteams/tools/bin) is where install
# puts the scanners and where they are looked for before the PATH.
# FLASHTEAMS_RULES_DIR (default ~/.flashteams/scan-rules) caches the rules.
# FLASHTEAMS_TRIVY_CACHE, when set, is Trivy's cache, which holds its
# vulnerability database; otherwise Trivy uses its own default.
# FLASHTEAMS_BIN names the flashteams command by its full path, in place of
# the one on the PATH.
# FLASHTEAMS_SCAN_TIMEOUT is how long one scanner may run, in seconds
# (default 1800). FLASHTEAMS_SCAN_PLATFORM (such as linux-x64) stands in for
# this computer's system and processor, for tests.

use 5.014;
use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use Digest::SHA ();
use Encode ();
use File::Basename qw(basename);
use File::Path qw(make_path remove_tree);
use File::Spec ();
use File::Temp qw(tempdir);
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP ();
use POSIX ();
use Time::HiRes ();

our $VERSION = '1.9.8';

my @SEVERITIES = qw(critical high medium low info);
my %SEVERITY_RANK = map { $SEVERITIES[$_] => $_ } 0 .. $#SEVERITIES;
my @CATEGORIES = qw(secret security hotspot sql iac dependency architecture);
my %CATEGORY = map { $_ => 1 } @CATEGORIES;

use constant {
    MAX_FINDINGS   => 500,               # findings in one payload
    SUMMARY_TOP    => 40,                # findings listed after a run
    MAX_RULE       => 300,
    MAX_TITLE      => 300,
    MAX_DETAIL     => 2000,
    MAX_SUMMARY    => 4000,
    MAX_REPORT     => 100000,
    MAX_NOTE       => 300,
    MAX_BUNDLE     => 50 * 1024 * 1024,  # bytes of a rules bundle
    MAX_READ       => 4 * 1024 * 1024,   # bytes of a source file read for its lines
    MAX_REPORT_RAW => 512 * 1024 * 1024, # bytes of a scanner's report
};

# Folders of built output and other people's code, left out of the code
# rules and the infrastructure checks.
my @SKIPPED_DIRS = qw(node_modules vendor dist build .venv venv .tox .git target .next .nuxt coverage
  __pycache__ bower_components third_party third-party Pods .yarn .terraform);

# Words and runs that made-up keys use, as FlashTeams' own scanner reads them.
my $MADE_UP = qr/your[_-]|<[^>]{1,40}>|\$\{|example|placeholder|changeme|dummy|fake|sample|redacted|test|xxxx|\*{4}|0123|1234|abcd/i;

# Code rules whose flagged line holds a password or key: like secrets, their
# line text is never kept and show hides it.
my $CREDENTIAL_RULE = qr/hard-?coded|credential/i;

# The scanners, pinned to the versions FlashTeams' own scanner uses. gitleaks
# and Trivy publish a checksums file with each release, and these are its
# sums; opengrep publishes signatures instead, so its sums are of the
# reviewed downloads, as the scanner's Dockerfile pins them.
my %PINS = (
    gitleaks => {
        version => '8.30.1',
        page    => 'https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1',
        base    => 'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/',
        member  => 'gitleaks',
        assets  => {
            'darwin-arm64' => [ 'gitleaks_8.30.1_darwin_arm64.tar.gz', 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5' ],
            'darwin-x64'   => [ 'gitleaks_8.30.1_darwin_x64.tar.gz',   'dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709' ],
            'linux-x64'    => [ 'gitleaks_8.30.1_linux_x64.tar.gz',    '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb' ],
            'linux-arm64'  => [ 'gitleaks_8.30.1_linux_arm64.tar.gz',  'e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080' ],
        },
    },
    opengrep => {
        version => '1.30.0',
        page    => 'https://github.com/opengrep/opengrep/releases/tag/v1.30.0',
        base    => 'https://github.com/opengrep/opengrep/releases/download/v1.30.0/',
        member  => undef,    # the download is the program itself
        assets  => {
            'darwin-arm64' => [ 'opengrep_osx_arm64',         '0f5bc3dec09d995c61331a4017b856ede508f90d95b018d95f1dc6166be89fdd' ],
            'darwin-x64'   => [ 'opengrep_osx_x86',           '650772a849a2986880982b7dea0371f96a75d354de95f94e8c1a2e6f8f6262d1' ],
            'linux-x64'    => [ 'opengrep_manylinux_x86',     '35779bdd72e92129c8df2a77f0c55e8c08356801ea92591ef32108d6b28d564c' ],
            'linux-arm64'  => [ 'opengrep_manylinux_aarch64', 'a5d5a4a58ba5d46ff51e921663da1c2bba38f4b03987f4aeec87f16c6ad3ecae' ],
        },
    },
    trivy => {
        version => '0.74.0',
        page    => 'https://github.com/aquasecurity/trivy/releases/tag/v0.74.0',
        base    => 'https://github.com/aquasecurity/trivy/releases/download/v0.74.0/',
        member  => 'trivy',
        assets  => {
            'darwin-arm64' => [ 'trivy_0.74.0_macOS-ARM64.tar.gz', '1caada5e0e2091909357c7525d3aa76f4b660b13821bc143b190c7483e31cc11' ],
            'darwin-x64'   => [ 'trivy_0.74.0_macOS-64bit.tar.gz', '472816f6888dda689d075c30254d4210b4d1035acf365aa72332f584c2f60485' ],
            'linux-x64'    => [ 'trivy_0.74.0_Linux-64bit.tar.gz', '2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a' ],
            'linux-arm64'  => [ 'trivy_0.74.0_Linux-ARM64.tar.gz', 'b94ce1976bbf3c15b514b605ee88be7c6d94a29be2302847ff01cb794d47aad5' ],
        },
    },
);
my @INSTALLABLE = qw(gitleaks opengrep trivy);

my $SELF = abs_path(__FILE__) // __FILE__;
my $BUNDLE_MARK = '.flashteams-rules.json';


sub main {
    my ($command, @args) = @_;
    $| = 1;
    binmode(STDOUT, ':encoding(UTF-8)');
    binmode(STDERR, ':encoding(UTF-8)');
    my %commands = (
        doctor  => \&cmd_doctor,
        install => \&cmd_install,
        rules   => \&cmd_rules,
        run     => \&cmd_run,
        show    => \&cmd_show,
        payload => \&cmd_payload,
        send    => \&cmd_send,
    );
    $command //= '';
    if ($command =~ /\A(?:help|--help|-h)\z/) {
        print usage();
        return 0;
    }
    my $handler = $commands{$command};
    if (!$handler) {
        print STDERR usage();
        return 2;
    }
    my $status = eval { $handler->(@args) };
    return $status if defined $status;
    my $error = $@;
    if (ref $error eq 'HASH') {
        print STDERR "flashteams-scan: $error->{message}\n";
        return $error->{code};
    }
    $error = chars("$error");
    chomp $error;
    print STDERR "flashteams-scan: something went wrong: $error\n";
    return 1;
}

sub usage {
    return <<'EOF';
Usage:
  perl flashteams-scan.pl doctor [--json]
  perl flashteams-scan.pl install <gitleaks|opengrep|trivy>...
  perl flashteams-scan.pl rules [--url <url> --sha256 <hex>] [--dir <cache>] [--organization-id <id>]
  perl flashteams-scan.pl run --kind security|sql [--mode quick|full] [--path <folder>]
      [--rules <folder>] [--out <work folder>]
  perl flashteams-scan.pl show --out <work folder> --ids 3,12,40 [--context <lines>]
  perl flashteams-scan.pl payload --out <work folder> --kind security|sql|architecture
      [--mode quick|full] [--path <folder>] --summary-file <file> --report-file <file>
      [--notes <file>] [--max-findings <n>] [--max-report-bytes <n>]
  perl flashteams-scan.pl send --out <work folder> [--product-id <id>] [--organization-id <id>]
EOF
}

# A failure the person or agent can act on: the message is printed as it is,
# and the program exits with the code (2 for a wrong command, 1 otherwise).
sub fail {
    my ($code, $message) = @_;
    die { code => $code, message => $message };
}

sub options {
    my ($command, $args, @spec) = @_;
    my %opt;
    my @rest = @$args;
    local $SIG{__WARN__} = sub { my ($w) = @_; chomp $w; fail(2, "$command: $w") };
    GetOptionsFromArray(\@rest, \%opt, @spec) or fail(2, "$command: the options are wrong. See: perl flashteams-scan.pl help");
    fail(2, "$command: unexpected argument: $rest[0]") if @rest;
    return \%opt;
}

# ---------------------------------------------------------------------------
# Small helpers.

# Text from a file or a program, as characters; bytes that are not UTF-8
# become U+FFFD instead of failing.
sub chars {
    my ($bytes) = @_;
    return undef unless defined $bytes;
    return $bytes if utf8::is_utf8($bytes);
    return Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT);
}

sub bytes_of { my ($text) = @_; return defined $text ? Encode::encode('UTF-8', $text) : undef }

sub json_codec { return JSON::PP->new->utf8->canonical->allow_nonref }

sub read_bytes {
    my ($path, $max) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    my $size = -s $fh;
    return undef if defined $max && defined $size && $size > $max;
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data // '';
}

sub read_json {
    my ($path, $max) = @_;
    my $bytes = read_bytes($path, $max);
    return undef unless defined $bytes;
    my $data = eval { json_codec()->decode($bytes) };
    return $data;
}

sub write_bytes {
    my ($path, $bytes) = @_;
    my $temp = "$path.tmp$$";
    open(my $fh, '>:raw', $temp) or fail(1, 'cannot write ' . chars($path) . ": $!");
    print {$fh} $bytes;
    close($fh) or fail(1, 'cannot write ' . chars($path) . ": $!");
    rename($temp, $path) or fail(1, 'cannot write ' . chars($path) . ": $!");
    return;
}

sub write_json {
    my ($path, $data) = @_;
    write_bytes($path, json_codec()->pretty->indent_length(2)->encode($data));
    return;
}

sub home {
    my $home = $ENV{HOME};
    $home = (getpwuid($<))[7] if !defined $home || $home eq '';
    return $home // '.';
}

sub is_windows { return $^O =~ /\A(?:MSWin32|msys|cygwin)\z/ }

sub tools_dir {
    my $dir = $ENV{FLASHTEAMS_TOOLS_DIR};
    return $dir if defined $dir && $dir ne '';
    return home() . '/.flashteams/tools/bin';
}

sub rules_cache {
    my ($given) = @_;
    return $given if defined $given && $given ne '';
    my $dir = $ENV{FLASHTEAMS_RULES_DIR};
    return $dir if defined $dir && $dir ne '';
    return home() . '/.flashteams/scan-rules';
}

sub scan_timeout {
    my $seconds = $ENV{FLASHTEAMS_SCAN_TIMEOUT} // '';
    return $seconds =~ /\A[1-9][0-9]{0,6}\z/ ? $seconds : 1800;
}

# This computer's system and processor, as the pins name them.
sub platform {
    if (($ENV{FLASHTEAMS_SCAN_PLATFORM} // '') =~ /\A([a-z]+)-([a-z0-9]+)\z/) {
        return ($1, $2);
    }
    my $os = $^O eq 'darwin' ? 'darwin' : $^O eq 'linux' ? 'linux' : is_windows() ? 'windows' : $^O;
    my $machine = (POSIX::uname())[4] // '';
    my $arch = $machine =~ /\A(?:arm64|aarch64)/i ? 'arm64' : $machine =~ /\A(?:x86_64|amd64|x64)\z/i ? 'x64' : lc $machine;
    if ($os eq 'darwin' && $arch eq 'x64') {
        # A Mac with Apple silicon running this Perl through Rosetta still
        # wants the arm64 scanners.
        my $result = capture([ '/usr/sbin/sysctl', '-n', 'hw.optional.arm64' ], timeout => 10);
        $arch = 'arm64' if $result->{status} == 0 && $result->{stdout} =~ /\A1\b/;
    }
    return ($os, $arch);
}

# The program's names on this system: gitleaks.exe as well on Windows.
sub program_names {
    my ($name) = @_;
    return is_windows() ? ("$name.exe", $name) : ($name);
}

# A program on the PATH, by its full path. Folders named relative to where
# this runs are skipped, so a repository cannot plant its own scanner.
sub on_path {
    my ($name) = @_;
    my $separator = $^O eq 'MSWin32' ? ';' : ':';
    for my $dir (split /\Q$separator\E/, $ENV{PATH} // '') {
        next unless $dir ne '' && File::Spec->file_name_is_absolute($dir);
        for my $program (program_names($name)) {
            my $path = "$dir/$program";
            return $path if -f $path && -x _;
        }
    }
    return undef;
}

# A scanner: in the tools folder first, where install puts the pinned
# versions, then on the PATH.
sub find_tool {
    my ($name) = @_;
    my $dir = tools_dir();
    if (File::Spec->file_name_is_absolute($dir)) {
        for my $program (program_names($name)) {
            my $path = "$dir/$program";
            return { path => $path, source => 'tools folder' } if -f $path && -x _;
        }
    }
    my $path = on_path($name);
    return $path ? { path => $path, source => 'PATH' } : undef;
}

my $SCRATCH;
sub scratch {
    $SCRATCH //= tempdir('flashteams-scan-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    return $SCRATCH;
}

# Runs a program with no shell in between: its input is the file given (or
# empty), its output and errors go to the files given (or nowhere, or with
# keep_output to this program's own), and it is stopped, with everything it
# started, after the timeout. env sets variables, and undef removes one.
sub run_program {
    my (%opt) = @_;
    my @command = @{ $opt{command} };
    my $pid = fork();
    fail(1, "cannot start $command[0]: $!") unless defined $pid;
    if (!$pid) {
        eval { setpgrp(0, 0) };
        if (defined $opt{cwd}) {
            chdir($opt{cwd}) or POSIX::_exit(127);
        }
        while (my ($key, $value) = each %{ $opt{env} || {} }) {
            if (defined $value) { $ENV{$key} = $value } else { delete $ENV{$key} }
        }
        open(STDIN, '<', $opt{stdin} // File::Spec->devnull) or POSIX::_exit(127);
        if (!$opt{keep_output}) {
            open(STDOUT, '>', $opt{stdout} // File::Spec->devnull) or POSIX::_exit(127);
            open(STDERR, '>', $opt{stderr} // File::Spec->devnull) or POSIX::_exit(127);
        }
        { no warnings 'exec'; exec { $command[0] } @command; }
        POSIX::_exit(127);
    }
    my $deadline = Time::HiRes::time() + ($opt{timeout} // 600);
    while (1) {
        my $done = waitpid($pid, POSIX::WNOHANG());
        if ($done == $pid || $done < 0) {
            my $raw = $?;
            return { status => $raw & 127 ? 128 + ($raw & 127) : $raw >> 8, timed_out => 0 };
        }
        if (Time::HiRes::time() > $deadline) {
            kill('TERM', -$pid) or kill('TERM', $pid);
            Time::HiRes::sleep(1);
            kill('KILL', -$pid) or kill('KILL', $pid);
            waitpid($pid, 0);
            return { status => 124, timed_out => 1 };
        }
        Time::HiRes::sleep(0.05);
    }
}

# run_program, with the output and errors kept and returned as bytes.
my $captures = 0;
sub capture {
    my ($command, %opt) = @_;
    my $dir = scratch();
    my $n = ++$captures;
    my ($out, $err) = ("$dir/out-$n", "$dir/err-$n");
    my $result = run_program(%opt, command => $command, stdout => $out, stderr => $err);
    $result->{stdout} = read_bytes($out) // '';
    $result->{stderr} = read_bytes($err) // '';
    unlink($out, $err);
    return $result;
}

# The first line of a program's errors, short, for a tool's note.
sub first_error {
    my ($bytes) = @_;
    my $text = chars($bytes // '');
    $text =~ s/\e\[[0-9;]*[A-Za-z]//g;
    my ($line) = grep { /\S/ } split /\r?\n/, $text;
    return clip($line // '', 200);
}

# Text on one line, cut to a length, without control characters.
sub clip {
    my ($text, $max) = @_;
    $text = defined $text ? "$text" : '';
    $text =~ s/[\x00-\x1f\x7f\x{2028}\x{2029}]+/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/\A //;
    $text =~ s/ \z//;
    $text = substr($text, 0, $max - 1) . "\x{2026}" if defined $max && length($text) > $max;
    return $text;
}

sub tool_version {
    my ($path, $name) = @_;
    my @args = $name eq 'gitleaks' ? ('version') : ('--version');
    my $result = capture([ $path, @args ], timeout => 120, env => { SEMGREP_SEND_METRICS => 'off' });
    return undef if $result->{timed_out};
    my $text = chars($result->{stdout} . "\n" . $result->{stderr});
    return $1 if $text =~ /\bv?(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.]+)?)\b/;
    return undef;
}

sub git_program {
    my $git = on_path('git');
    fail(1, 'git is not installed, and the scan needs it to find the repository.') unless $git;
    return $git;
}

sub git {
    my ($root, @args) = @_;
    return capture([ git_program(), @args ], cwd => $root, timeout => 300, env => { GIT_TERMINAL_PROMPT => '0', GIT_OPTIONAL_LOCKS => '0' });
}

sub git_line {
    my ($root, @args) = @_;
    my $result = git($root, @args);
    return undef unless $result->{status} == 0;
    my ($line) = split /\r?\n/, $result->{stdout};
    return defined $line && $line ne '' ? chars($line) : undef;
}

# The root of the git working tree around the current folder, as bytes.
sub repo_root {
    my $here = getcwd();
    my $inside = git($here, 'rev-parse', '--is-inside-work-tree');
    if ($inside->{status} != 0 || $inside->{stdout} !~ /\Atrue/) {
        my $why = first_error($inside->{stderr});
        fail(1, 'Run this inside a git working tree; git found none here' . ($why ne '' ? " ($why)." : '.'));
    }
    my $result = git($here, 'rev-parse', '--show-cdup');
    fail(1, 'git could not find the root of this repository: ' . first_error($result->{stderr})) if $result->{status} != 0;
    (my $up = $result->{stdout}) =~ s/\r?\n\z//;
    my $root = abs_path($up eq '' ? $here : "$here/$up");
    fail(1, 'git could not find the root of this repository.') unless defined $root && -d $root;
    return $root;
}

# The folder to scan, relative to the root, as given: '' for the whole
# repository. It must be inside the repository.
sub scan_path {
    my ($given, $root) = @_;
    my $path = $given // '';
    $path =~ s{\\}{/}g;
    $path =~ s{\A(?:\./)+}{};
    $path =~ s{/+\z}{};
    $path =~ s{//+}{/}g;
    $path = '' if $path eq '.';
    return '' if $path eq '';
    fail(2, "--path is a folder relative to the repository root, not $path")
      if $path =~ m{\A/} || $path =~ m{\A[A-Za-z]:} || grep { $_ eq '..' || $_ eq '.' } split m{/}, $path;
    fail(2, "--path $path is not a folder in this repository") if defined $root && !-d ("$root/" . bytes_of($path));
    return $path;
}

sub path_label {
    my ($path) = @_;
    return $path eq '' ? 'the whole repository' : "$path/";
}

sub timestamp {
    my @t = localtime();
    return POSIX::strftime('%Y%m%d-%H%M%S', @t);
}

sub iso_now { return POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()) }

# ---------------------------------------------------------------------------
# doctor: which scanners are here, and how to install the missing ones.

sub cmd_doctor {
    my $opt = options('doctor', \@_, 'json');
    my ($os, $arch) = platform();
    my @rows;
    for my $name (qw(gitleaks opengrep semgrep trivy git curl)) {
        my $tool = find_tool($name);
        my $version = $tool ? tool_version($tool->{path}, $name) : undef;
        push @rows, {
            name    => $name,
            found   => $tool ? JSON::PP::true : JSON::PP::false,
            path    => $tool ? chars($tool->{path}) : undef,
            source  => $tool ? $tool->{source} : undef,
            version => $version,
            pinned  => $PINS{$name} ? $PINS{$name}{version} : undef,
        };
    }
    my %row = map { $_->{name} => $_ } @rows;
    my @missing = grep { !$row{$_}{found} } @INSTALLABLE;
    my $brew = $os eq 'darwin' && on_path('brew');
    my $can_install = $os ne 'windows' && $row{curl}{found};
    my $script = chars($SELF);
    my %choices;
    for my $name (@missing) {
        my @ways;
        push @ways, qq{perl "$script" install $name} if $can_install && $PINS{$name}{assets}{"$os-$arch"};
        push @ways, "brew install $name" if $brew && $name ne 'opengrep';
        push @ways, $PINS{$name}{page} if !@ways;
        $choices{$name} = \@ways;
    }
    my $semgrep_stands_in = !$row{opengrep}{found} && $row{semgrep}{found};

    if ($opt->{json}) {
        print json_codec()->pretty->indent_length(2)->encode({
            platform         => "$os-$arch",
            tools_dir        => chars(tools_dir()),
            install_works    => $can_install ? JSON::PP::true : JSON::PP::false,
            tools            => \@rows,
            missing          => \@missing,
            semgrep_for_opengrep => $semgrep_stands_in ? JSON::PP::true : JSON::PP::false,
            install          => \%choices,
            install_all      => @missing && $can_install ? qq{perl "$script" install @missing} : undef,
            brew_all         => $brew && grep({ $_ ne 'opengrep' } @missing)
                ? 'brew install ' . join(' ', grep { $_ ne 'opengrep' } @missing) : undef,
        });
        return 0;
    }

    print 'Scanners for the FlashTeams skills (tools folder: ' . chars(tools_dir()) . ")\n";
    for my $row (@rows) {
        my $status;
        if ($row->{found}) {
            $status = sprintf('%-8s ready (%s%s)', $row->{version} // '?', $row->{source},
                $row->{source} eq 'PATH' ? ": $row->{path}" : '');
            $status .= ". FlashTeams uses $row->{pinned}" if $row->{pinned} && ($row->{version} // '') ne $row->{pinned};
        }
        elsif ($row->{name} eq 'semgrep') {
            $status = 'not installed (only needed when opengrep is missing)';
        }
        else {
            $status = 'missing';
        }
        printf "  %-9s %s\n", $row->{name}, $status;
    }
    print "  semgrep will run FlashTeams' code rules in place of opengrep.\n" if $semgrep_stands_in;
    print "  git is missing, and every scan needs it.\n" unless $row{git}{found};
    if (!@missing) {
        print "Every scanner is installed.\n";
        return 0;
    }
    print "Missing: @missing\n";
    print "To install, choose one way for each:\n";
    print "  $_: " . join('   or   ', @{ $choices{$_} }) . "\n" for @missing;
    if ($can_install && @missing > 1) {
        print qq{All at once: perl "$script" install @missing\n};
    }
    my @brewable = grep { $_ ne 'opengrep' } @missing;
    print "With Homebrew: brew install @brewable\n" if $brew && @brewable;
    if ($can_install) {
        print 'install downloads the version FlashTeams uses into ' . chars(tools_dir())
          . " and checks it against a pinned checksum. Nothing else on this computer changes.\n";
    }
    elsif ($os eq 'windows') {
        print "install does not work on Windows. Download each scanner from its release page above.\n";
    }
    elsif (!$row{curl}{found}) {
        print "install needs curl, which is missing.\n";
    }
    return 0;
}

# ---------------------------------------------------------------------------
# install: the pinned scanners, into the tools folder.

sub sha256_file {
    my ($path) = @_;
    my $sha = Digest::SHA->new(256);
    open(my $fh, '<:raw', $path) or return '';
    $sha->addfile($fh);
    return $sha->hexdigest;
}

sub cmd_install {
    my @tools = @_;
    fail(2, 'install: name the scanners to install: ' . join(', ', @INSTALLABLE)) unless @tools;
    for my $tool (@tools) {
        next if $PINS{$tool};
        my $more = $tool eq 'semgrep' ? ' install does not install semgrep; install opengrep, which runs the same rules.' : '';
        fail(2, "install: $tool is not a scanner this installs. Choose from: @INSTALLABLE.$more");
    }
    my ($os, $arch) = platform();
    if ($os eq 'windows') {
        print "install does not work on Windows. Download each scanner from its release page and put it on the PATH:\n";
        print "  $_ $PINS{$_}{version}: $PINS{$_}{page}\n" for @tools;
        return 1;
    }
    my $curl = on_path('curl');
    fail(1, 'install needs curl, which is not installed.') unless $curl;
    my $dir = tools_dir();
    fail(1, 'FLASHTEAMS_TOOLS_DIR must be a full path, not ' . chars($dir)) unless File::Spec->file_name_is_absolute($dir);
    make_path($dir);
    fail(1, 'cannot make the tools folder ' . chars($dir)) unless -d $dir && -w _;

    my $failed = 0;
    for my $tool (@tools) {
        my $pin = $PINS{$tool};
        my $asset = $pin->{assets}{"$os-$arch"};
        if (!$asset) {
            print "$tool: no pinned build for $os-$arch. Get it from $pin->{page}\n";
            $failed++;
            next;
        }
        my ($name, $sum) = @$asset;
        my $work = tempdir(".install-$tool-XXXXXX", DIR => $dir, CLEANUP => 1);
        my $download = "$work/$name";
        print "$tool: downloading $name ($pin->{version})...\n";
        my $result = capture(
            [ $curl, '-fsSL', '--proto', '=https', '--proto-redir', '=https', '--retry', '2', '-o', $download, "$pin->{base}$name" ],
            timeout => 900
        );
        if ($result->{status} != 0 || !-f $download) {
            print "$tool: the download failed: " . (first_error($result->{stderr}) || "curl exited $result->{status}") . "\n";
            remove_tree($work);
            $failed++;
            next;
        }
        my $got = sha256_file($download);
        if ($got ne $sum) {
            print "$tool: the download does not match its pinned checksum, so nothing was installed.\n";
            print "  expected $sum\n  got      $got\n";
            remove_tree($work);
            $failed++;
            next;
        }
        my $program = $download;
        if (defined $pin->{member}) {
            my $unpack = capture([ 'tar', '-xzf', $download, '-C', $work, $pin->{member} ], timeout => 300);
            unlink($download);
            $program = "$work/$pin->{member}";
            if ($unpack->{status} != 0 || !-f $program) {
                print "$tool: could not unpack the download: " . first_error($unpack->{stderr}) . "\n";
                remove_tree($work);
                $failed++;
                next;
            }
        }
        chmod(0755, $program);
        my $target = "$dir/$tool";
        if (!rename($program, $target)) {
            print "$tool: could not put it in " . chars($dir) . ": $!\n";
            remove_tree($work);
            $failed++;
            next;
        }
        remove_tree($work);
        my $version = tool_version($target, $tool);
        if (!defined $version) {
            print "$tool: installed in " . chars($dir) . ", but it did not start. Check it runs on this computer.\n";
            $failed++;
            next;
        }
        print "$tool $version: installed in " . chars($dir) . "\n";
    }
    return $failed ? 1 : 0;
}

# ---------------------------------------------------------------------------
# rules: FlashTeams' rules bundle, checked and unpacked into the cache.

# A path inside the bundle: plain relative pieces, never absolute, never
# with .. anywhere.
sub bundle_path_ok {
    my ($path) = @_;
    return 0 unless defined $path && !ref $path && $path ne '' && length($path) <= 300;
    return 0 if index($path, '..') >= 0;
    return 0 if $path =~ m{\A[/\\]} || $path =~ m{\A[A-Za-z]:} || $path =~ m{\\};
    return 0 if $path =~ /[\x00-\x1f\x7f]/;
    for my $piece (split m{/}, $path, -1) {
        return 0 if $piece eq '' || $piece eq '.' || $piece !~ /\A[A-Za-z0-9_][A-Za-z0-9._ -]*\z/;
    }
    return 0 if $path eq $BUNDLE_MARK;
    return 1;
}

# Checks a bundle's bytes against the checksum and its contents against the
# format. Returns the bundle, or fails saying why.
sub check_bundle {
    my ($bytes, $sha256) = @_;
    my $got = Digest::SHA::sha256_hex($bytes);
    fail(1, "The rules download does not match its checksum (expected $sha256, got $got), so it was not used.")
      unless $got eq lc $sha256;
    my $bundle = eval { json_codec()->decode($bytes) };
    fail(1, 'The rules download is not a FlashTeams rules bundle.') unless ref $bundle eq 'HASH';
    fail(1, 'The rules bundle is format ' . ($bundle->{format} // 'unknown') . ', which this helper does not read. Update the plugin.')
      unless defined $bundle->{format} && !ref $bundle->{format} && $bundle->{format} eq '1';
    my $version = $bundle->{version};
    fail(1, 'The rules bundle has no usable version.')
      unless defined $version && !ref $version && $version =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/ && index($version, '..') < 0;
    my $files = $bundle->{files};
    fail(1, 'The rules bundle has no files.') unless ref $files eq 'HASH' && %$files;
    for my $path (sort keys %$files) {
        fail(1, "The rules bundle names a file outside its folder ($path), so it was not used.") unless bundle_path_ok($path);
        fail(1, "The rules bundle's file $path is not text.") unless defined $files->{$path} && !ref $files->{$path};
    }
    return $bundle;
}

# A copy of the bundle with this checksum already unpacked in the cache.
sub cached_bundle {
    my ($cache, $sha256) = @_;
    opendir(my $dh, $cache) or return undef;
    my @dirs = grep { !/\A\./ && -d "$cache/$_" } readdir($dh);
    closedir($dh);
    for my $dir (sort @dirs) {
        my $mark = read_json("$cache/$dir/$BUNDLE_MARK", 16 * 1024 * 1024);
        next unless ref $mark eq 'HASH' && ($mark->{sha256} // '') eq lc $sha256 && ref $mark->{files} eq 'ARRAY';
        next unless ($mark->{version} // '') eq $dir;
        next if grep { !-f ("$cache/$dir/" . bytes_of($_)) } @{ $mark->{files} };
        return "$cache/$dir";
    }
    return undef;
}

# A FlashTeams tool's answer from the flashteams command's stdout. The
# command prints the tool's own JSON; with --output json it wraps it as
# {"text": "<that JSON>"}, and an MCP result may carry it under result. Any
# of the three reads the same.
sub tool_answer {
    my ($stdout) = @_;
    my $answer = eval { json_codec()->decode($stdout) };
    for (1 .. 2) {
        last unless ref $answer eq 'HASH' && !exists $answer->{success} && !exists $answer->{url};
        if (defined $answer->{text} && !ref $answer->{text}) {
            my $inner = eval { json_codec()->decode($answer->{text}) };
            $answer = $inner if ref $inner eq 'HASH';
        }
        elsif (ref $answer->{result} eq 'HASH') {
            $answer = $answer->{result};
        }
    }
    return $answer;
}

# The rules' address and checksum from FlashTeams, through the flashteams
# command: get_scan_rules, which only reads. A refusal is passed on with the
# command's own exit code.
sub ask_for_rules {
    my ($organization) = @_;
    my $program = flashteams_program();
    my $result = capture(
        [ $program, 'get_scan_rules', (defined $organization && $organization ne '' ? "--organization_id=$organization" : ()) ],
        timeout => 300
    );
    my $answer = tool_answer($result->{stdout});
    if ($result->{status} != 0 || ref $answer ne 'HASH' || (exists $answer->{success} && !$answer->{success})) {
        my $why = ref $answer eq 'HASH' ? clip($answer->{reason} // $answer->{message} // $answer->{error} // '', 300) : '';
        $why = first_error($result->{stderr}) if $why eq '';
        fail($result->{timed_out} ? 5 : $result->{status} || 1, 'FlashTeams did not give the scan rules (get_scan_rules' . ($result->{timed_out} ? ' took too long' : " exited $result->{status}")
              . ')' . ($why ne '' ? ": $why" : '.'));
    }
    my ($url, $sha256) = map { defined && !ref ? "$_" : undef } @$answer{qw(url sha256)};
    fail(1, 'FlashTeams answered get_scan_rules without a url and sha256.') unless defined $url && defined $sha256;
    return ($url, $sha256);
}

sub cmd_rules {
    my $opt = options('rules', \@_, 'url=s', 'sha256=s', 'dir=s', 'organization-id=s');
    my ($url, $sha256) = ($opt->{url}, $opt->{sha256});
    if (!defined $url && !defined $sha256) {
        ($url, $sha256) = ask_for_rules($opt->{'organization-id'});
    }
    fail(2, 'rules: give both --url and --sha256 (from get_scan_rules), or neither to ask FlashTeams through the flashteams command')
      unless defined $url && defined $sha256;
    $sha256 = lc $sha256;
    fail(2, 'rules: --sha256 is 64 hex digits') unless $sha256 =~ /\A[0-9a-f]{64}\z/;
    fail(2, 'rules: --url is an https address') unless $url =~ m{\A(?:https|file)://}i;
    my $cache = rules_cache($opt->{dir});
    make_path($cache);
    fail(1, 'cannot make the rules folder ' . chars($cache)) unless -d $cache && -w _;
    $cache = abs_path($cache) // $cache;

    if (my $found = cached_bundle($cache, $sha256)) {
        print STDERR "Using the FlashTeams rules already downloaded.\n";
        print chars($found), "\n";
        return 0;
    }

    my $curl = on_path('curl');
    fail(1, 'Downloading the rules needs curl, which is not installed.') unless $curl;
    my $work = tempdir('.download-XXXXXX', DIR => $cache, CLEANUP => 1);
    my $download = "$work/bundle.json";
    # https only (file:// is for tests), with redirects kept to https.
    my $result = capture(
        [ $curl, '-fsSL', '--proto', '=https,file', '--proto-redir', '=https', '--max-filesize', MAX_BUNDLE, '-o', $download, $url ],
        timeout => 300
    );
    if ($result->{status} != 0 || !-f $download) {
        remove_tree($work);
        my $why = first_error($result->{stderr}) || "curl exited $result->{status}";
        fail(1, "The rules download failed: $why. The link works once, within two minutes; ask FlashTeams for a new one (get_scan_rules).");
    }
    my $bytes = read_bytes($download, MAX_BUNDLE);
    unlink($download);
    if (!defined $bytes) {
        remove_tree($work);
        fail(1, 'The rules download is too large.');
    }
    my $bundle = eval { check_bundle($bytes, $sha256) };
    if (!$bundle) {
        my $error = $@;
        remove_tree($work);
        die $error;
    }

    my $version = $bundle->{version};
    my $staging = "$work/$version";
    my @paths = sort keys %{ $bundle->{files} };
    for my $path (@paths) {
        my $file = "$staging/" . bytes_of($path);
        (my $folder = $file) =~ s{/[^/]+\z}{};
        make_path($folder);
        write_bytes($file, bytes_of($bundle->{files}{$path}));
    }
    write_json("$staging/$BUNDLE_MARK", {
        format     => 1,
        version    => $version,
        sha256     => $sha256,
        tools      => ref $bundle->{tools} eq 'HASH' ? $bundle->{tools} : {},
        files      => \@paths,
        downloaded => iso_now(),
    });
    my $target = "$cache/$version";
    remove_tree($target) if -e $target;
    rename($staging, $target) or do { remove_tree($work); fail(1, 'cannot put the rules in ' . chars($target) . ": $!") };
    remove_tree($work);
    print STDERR "Downloaded the FlashTeams rules, version $version.\n";
    print chars($target), "\n";
    return 0;
}

# The unpacked bundle a scan uses, and its version.
sub rules_in {
    my ($given) = @_;
    return (undef, undef) unless defined $given && $given ne '';
    my $dir = abs_path($given);
    fail(1, "--rules $given is not a folder") unless defined $dir && -d $dir;
    my $mark = read_json("$dir/$BUNDLE_MARK", 16 * 1024 * 1024);
    my $version = ref $mark eq 'HASH' && defined $mark->{version} && !ref $mark->{version} ? $mark->{version} : chars(basename($dir));
    return ($dir, $version);
}

# The rule files in one of the bundle's folders.
sub rule_files {
    my ($dir) = @_;
    return () unless defined $dir && opendir(my $dh, $dir);
    my @files = sort grep { /\.ya?ml\z/ && -f "$dir/$_" } readdir($dh);
    closedir($dh);
    return map { "$dir/$_" } @files;
}

# ---------------------------------------------------------------------------
# run: the scanners, one after another, and their findings in one list.

sub cmd_run {
    my $opt = options('run', \@_, 'kind=s', 'mode=s', 'path=s', 'rules=s', 'out=s');
    $opt->{path} = chars($opt->{path}) if defined $opt->{path};
    my $kind = $opt->{kind} // '';
    fail(2, 'run: --kind is security or sql') unless $kind =~ /\A(?:security|sql)\z/;
    my $mode = $opt->{mode} // 'quick';
    fail(2, 'run: --mode is quick or full') unless $mode =~ /\A(?:quick|full)\z/;
    my $root = repo_root();
    my $path = scan_path($opt->{path}, $root);
    my ($rules, $rules_version) = rules_in($opt->{rules});
    my $out = work_folder($opt->{out}, $root, $kind);
    unlink("$out/payload.json");

    my $ctx = {
        kind          => $kind,
        mode          => $mode,
        root          => $root,
        path          => $path,
        target        => $path eq '' ? '.' : bytes_of($path),
        rules         => $rules,
        raw           => tempdir('.raw-XXXXXX', DIR => $out, CLEANUP => 1),
        visible       => visible_files($root, $path),
        findings      => [],
        tools         => [],
        started       => iso_now(),
    };
    run_gitleaks($ctx);
    run_code_rules($ctx);
    if ($kind eq 'security') {
        run_trivy_config($ctx);
        run_trivy_vuln($ctx);
    }
    remove_tree($ctx->{raw});

    my @findings = finish_findings($ctx);
    my %hidden;
    for my $i (0 .. $#findings) {
        my $hide = delete $findings[$i]{_hide};
        $hidden{ $i + 1 } = $hide if $hide;
        delete @{ $findings[$i] }{ grep { /\A_/ } keys %{ $findings[$i] } };
    }
    write_json("$out/findings.json", \@findings);
    write_json("$out/hidden.json", \%hidden);
    write_json("$out/tools.json", $ctx->{tools});
    write_json("$out/scan.json", {
        format        => 1,
        helper        => $VERSION,
        kind          => $kind,
        mode          => $mode,
        path          => $path,
        rules_version => $rules_version,
        root          => chars($root),
        started       => $ctx->{started},
        finished      => iso_now(),
        findings      => scalar(@findings),
    });
    print_summary($ctx, $out, $rules_version, \@findings);
    return 0;
}

# The work folder: as given, else one of its own under the system's
# temporary folder. Never inside the repository, so the scan does not read
# its own output.
sub work_folder {
    my ($given, $root, $kind) = @_;
    my $out = $given;
    if (!defined $out || $out eq '') {
        my $tmp = $ENV{TMPDIR} // '';
        $tmp = '/tmp' if $tmp eq '' || !-d $tmp;
        $tmp =~ s{/+\z}{};
        (my $name = basename($root)) =~ s/[^A-Za-z0-9._-]+/-/g;
        $out = "$tmp/flashteams-scan/$name-$kind-" . timestamp();
    }
    my $where = full_path($out);
    fail(1, 'Keep the work folder outside the repository, so the scan does not read its own files: ' . chars($where))
      if $where eq $root || index($where, "$root/") == 0;
    make_path($out);
    my $full = abs_path($out);
    fail(1, 'cannot make the work folder ' . chars($out)) unless defined $full && -d $full && -w _;
    return $full;
}

# A folder's full path with links resolved, whether or not it exists yet:
# the nearest folder above it that exists, resolved, and the rest as given.
sub full_path {
    my ($path) = @_;
    my @rest;
    my $here = File::Spec->rel2abs($path);
    while (!-e $here) {
        my ($volume, $dirs, $last) = File::Spec->splitpath($here);
        unshift @rest, $last;
        my $up = File::Spec->catpath($volume, $dirs, '');
        $up =~ s{/+\z}{} if length($up) > 1;
        last if $up eq $here || $up eq '';
        $here = $up;
    }
    my $base = abs_path($here) // $here;
    return join('/', $base, grep { $_ ne '' && $_ ne '.' } @rest);
}

# Every file git shows in the folder: tracked, or new and not ignored. A
# finding in any other file (built output, a dependency, a .env file git
# ignores) is not part of the code and is left out.
sub visible_files {
    my ($root, $path) = @_;
    my $result = git($root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', $path eq '' ? '.' : bytes_of($path));
    fail(1, 'git could not list the files: ' . first_error($result->{stderr})) if $result->{status} != 0;
    my %visible = map { $_ => 1 } grep { $_ ne '' } split /\0/, $result->{stdout};
    return \%visible;
}

sub add_tool {
    my ($ctx, $name, $version, $status, $note) = @_;
    push @{ $ctx->{tools} }, { name => $name, version => $version, status => $status, note => clip($note, MAX_NOTE) };
    return;
}

sub missing_note {
    my ($name) = @_;
    return "not installed. Install it with: perl flashteams-scan.pl install $name";
}

sub plural {
    my ($n, $word) = @_;
    return "$n $word" . ($n == 1 ? '' : 's');
}

# A path a scanner reported, made relative to the repository root.
sub repo_path {
    my ($ctx, $reported) = @_;
    return undef unless defined $reported && !ref $reported && $reported ne '';
    my $path = "$reported";
    $path =~ s{\\}{/}g;
    my $root = chars($ctx->{root});
    if (index($path, "$root/") == 0) {
        $path = substr($path, length($root) + 1);
    }
    $path =~ s{\A(?:\./)+}{};
    return $path if $ctx->{path} eq '' || -e ("$ctx->{root}/" . bytes_of($path));
    my $joined = "$ctx->{path}/$path";
    return -e ("$ctx->{root}/" . bytes_of($joined)) ? $joined : $path;
}

sub positive {
    my ($n) = @_;
    return defined $n && !ref $n && $n =~ /\A[0-9]+\z/ && $n >= 1 ? 0 + $n : undef;
}

sub words_of {
    my ($id) = @_;
    (my $words = $id) =~ s/[-_]+/ /g;
    return $words;
}

# The environment a scanner runs with: its own temporary folder, and no
# setting that would point gitleaks at another configuration.
sub tool_env {
    my ($ctx, %more) = @_;
    return {
        TMPDIR               => $ctx->{raw},
        GITLEAKS_CONFIG      => undef,
        GITLEAKS_CONFIG_TOML => undef,
        SEMGREP_SEND_METRICS => 'off',
        %more,
    };
}

# A proxy nothing listens on, so a check that should stay offline fails at
# once instead of fetching.
my %NO_NETWORK = map { $_ => 'http://127.0.0.1:9' } qw(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy);
$NO_NETWORK{$_} = '' for qw(NO_PROXY no_proxy);

# gitleaks: its own default rules, then FlashTeams' secret rules when the
# bundle has them.
sub run_gitleaks {
    my ($ctx) = @_;
    my $tool = find_tool('gitleaks');
    if (!$tool) {
        add_tool($ctx, 'gitleaks', undef, 'missing', missing_note('gitleaks'));
        return;
    }
    my $version = tool_version($tool->{path}, 'gitleaks');
    my $own = $ctx->{rules} && -f "$ctx->{rules}/gitleaks/flashteams.toml" ? "$ctx->{rules}/gitleaks/flashteams.toml" : undef;
    my @passes = ([ 'default', undef ], $own ? [ 'flashteams', $own ] : ());
    my (@notes, @found);
    my $ran = 0;
    for my $pass (@passes) {
        my ($name, $config) = @$pass;
        my $report = "$ctx->{raw}/gitleaks-$name.json";
        my $err = "$ctx->{raw}/gitleaks-$name.err";
        my $result = run_program(
            command => [
                $tool->{path}, 'dir', $ctx->{target}, '--report-format', 'json', '--report-path', $report, '--no-banner',
                '--exit-code', '0', '--max-target-megabytes', '5', '--log-level', 'error', '--redact',
                ($config ? ('--config', $config) : ()),
            ],
            cwd => $ctx->{root}, env => tool_env($ctx), stderr => $err, timeout => scan_timeout(),
        );
        my $data = read_json($report, MAX_REPORT_RAW);
        my $why = first_error(read_bytes($err));
        unlink($report, $err);
        if ($result->{timed_out}) {
            push @notes, ($name eq 'default' ? 'its own rules' : "FlashTeams' rules") . ' ran out of time';
            next;
        }
        if (ref $data ne 'ARRAY') {
            push @notes, ($name eq 'default' ? 'its own rules' : "FlashTeams' rules") . ' failed' . ($why ne '' ? ": $why" : '');
            next;
        }
        $ran++;
        push @found, map { gitleaks_finding($ctx, $_) } @$data;
    }
    my @kept = grep { defined } @found;
    my $left = keep_visible($ctx, \@kept);
    if ($ran) {
        unshift @notes, $own ? "its own rules and FlashTeams' secret rules" : "its own rules only (FlashTeams rules not downloaded)";
        push @notes, "left out $left in files git ignores" if $left;
        if ($ctx->{kind} eq 'sql') {
            my $all = @kept;
            @kept = grep { defined $_->{path} && $_->{path} =~ /\.sql\z/i } @kept;
            push @notes, scalar(@kept) . " of $all in .sql files";
        }
        else {
            push @notes, plural(scalar @kept, 'finding');
        }
    }
    push @{ $ctx->{findings} }, @kept;
    add_tool($ctx, 'gitleaks', $version, $ran ? 'ran' : 'failed', join('; ', @notes));
    return;
}

# One gitleaks finding. The secret is dropped here, before anything else
# reads the finding.
sub gitleaks_finding {
    my ($ctx, $raw) = @_;
    return undef unless ref $raw eq 'HASH';
    delete @$raw{qw(Secret Match Line)};
    my $id = defined $raw->{RuleID} && !ref $raw->{RuleID} ? "$raw->{RuleID}" : 'secret';
    my $ours = $id =~ /\Aflashteams-/;
    my $description = clip($raw->{Description}, MAX_DETAIL);
    my $path = repo_path($ctx, $raw->{File});
    my $line = positive($raw->{StartLine});
    my ($title, $recommendation);
    if ($id eq 'flashteams-committed-env-file') {
        $title = $description || 'An environment file is in the repository.';
        $recommendation = 'Remove the file from the repository, add it to .gitignore, and revoke any key it held.';
    }
    elsif ($ours) {
        $title = $description || 'A value that looks like a key or password.';
        $recommendation = 'If it is a real key, revoke it, then load it from the environment or a secret store instead.';
    }
    else {
        $title = 'Secret written in the code: ' . words_of($id) . '.';
        $recommendation = 'If it is real, revoke it with its provider first, then remove it from the code and from the git history, and load it from the environment or a secret store.';
    }
    my $end = positive($raw->{EndLine}) // $line;
    return {
        category       => 'secret',
        tool           => 'gitleaks',
        rule           => clip("gitleaks:$id", MAX_RULE),
        severity       => $ours ? 'medium' : 'critical',
        path           => $path,
        line           => $line,
        title          => clip($title, MAX_TITLE),
        detail         => $ours ? '' : $description,
        recommendation => $recommendation,
        cwe            => 'CWE-798',
        _text          => '',
        _column        => positive($raw->{StartColumn}) // 0,
        _hide          => defined $path && defined $line ? {
            path         => $path,
            line         => $line,
            end_line     => $end < $line ? $line : $end,
            start_column => positive($raw->{StartColumn}),
            end_column   => positive($raw->{EndColumn}),
        } : undef,
    };
}

# Leaves out findings in files git does not show; returns how many.
sub keep_visible {
    my ($ctx, $findings) = @_;
    my $before = @$findings;
    @$findings = grep { !defined $_->{path} || $ctx->{visible}{ bytes_of($_->{path}) } } @$findings;
    return $before - @$findings;
}

# FlashTeams' code rules, with opengrep, else semgrep.
sub run_code_rules {
    my ($ctx) = @_;
    my $engine = 'opengrep';
    my $tool = find_tool('opengrep');
    if (!$tool && ($tool = find_tool('semgrep'))) {
        $engine = 'semgrep';
    }
    my @folders = $ctx->{kind} eq 'sql' ? qw(sql security) : qw(security hotspot);
    if (!$ctx->{rules}) {
        add_tool($ctx, $tool ? $engine : 'opengrep', $tool ? tool_version($tool->{path}, $engine) : undef, 'skipped',
            'FlashTeams rules not downloaded');
        return;
    }
    if (!$tool) {
        add_tool($ctx, 'opengrep', undef, 'missing', missing_note('opengrep'));
        return;
    }
    my $version = tool_version($tool->{path}, $engine);
    my @configs = grep { rule_files($_) } map { "$ctx->{rules}/opengrep/$_" } @folders;
    if (!@configs) {
        add_tool($ctx, $engine, $version, 'skipped', 'the FlashTeams rules have no code rules for this scan');
        return;
    }
    # Rules from the sql folder always count for a SQL audit; the security
    # rules count when they are about SQL or NoSQL injection.
    my %sql_rule;
    if ($ctx->{kind} eq 'sql') {
        for my $file (rule_files("$ctx->{rules}/opengrep/sql")) {
            my $text = chars(read_bytes($file) // '');
            $sql_rule{$1} = 1 while $text =~ /^\s*-?\s*id:\s*["']?([^\s"'#]+)/mg;
        }
    }
    my $report = "$ctx->{raw}/rules.json";
    my $err = "$ctx->{raw}/rules.err";
    my $result = run_program(
        command => [
            $tool->{path}, 'scan', (map { ('--config', $_) } @configs), "--json-output=$report", '--disable-version-check',
            '--no-git-ignore', '--no-rewrite-rule-ids', ($engine eq 'opengrep' ? '--taint-intrafile' : '--metrics=off'),
            '--timeout', '5', '--timeout-threshold', '3', '--max-target-bytes', '1000000', '--quiet',
            (map { "--exclude=$_" } @SKIPPED_DIRS, '*.min.js'), $ctx->{target},
        ],
        cwd => $ctx->{root}, env => tool_env($ctx), stderr => $err, timeout => scan_timeout(),
    );
    my $data = read_json($report, MAX_REPORT_RAW);
    my $why = first_error(read_bytes($err));
    unlink($report, $err);
    if ($result->{timed_out}) {
        add_tool($ctx, $engine, $version, 'failed', 'ran out of time on this repository; scan a smaller folder with --path');
        return;
    }
    if (ref $data ne 'HASH' || ref $data->{results} ne 'ARRAY') {
        add_tool($ctx, $engine, $version, 'failed', 'did not finish' . ($why ne '' ? ": $why" : " (exit $result->{status})"));
        return;
    }
    $ctx->{engine} = $engine;
    # A rule can match the same code twice, through two of its patterns:
    # that is one finding.
    my %same;
    my @found = grep { defined && !$same{ $_->{_span} }++ } map { code_rule_finding($ctx, $_) } @{ $data->{results} };
    my @notes = ('FlashTeams rules: ' . join(', ', map { m{/([^/]+)\z} ? $1 : $_ } @configs));
    my $left = keep_visible($ctx, \@found);
    push @notes, "left out $left in files git ignores" if $left;
    if ($ctx->{kind} eq 'sql') {
        my $all = @found;
        @found = grep { $sql_rule{ $_->{_rule_id} } || $_->{_rule_id} =~ /sql/i } @found;
        push @notes, scalar(@found) . " of $all about SQL";
    }
    else {
        push @notes, plural(scalar @found, 'finding');
    }
    push @{ $ctx->{findings} }, @found;
    my $errors = ref $data->{errors} eq 'ARRAY' ? @{ $data->{errors} } : 0;
    push @notes, plural($errors, 'file') . ' it could not read fully' if $errors;
    add_tool($ctx, $engine, $version, 'ran', join('; ', @notes));
    return;
}

my %IMPACT = (blocker => 'critical', critical => 'critical', high => 'high', medium => 'medium', low => 'low', info => 'info');
my %RULE_SEVERITY = (ERROR => 'high', WARNING => 'medium', INFO => 'low', CRITICAL => 'critical', HIGH => 'high', MEDIUM => 'medium', LOW => 'low');

# A rule's message: its first sentence is the title, the rest the detail.
sub split_message {
    my ($message) = @_;
    my $text = clip($message);
    return ('This code matches a FlashTeams rule.', '') if $text eq '';
    if ($text =~ /\A(.+?[.!?])\s+(?=[A-Z0-9("'`\[])(.+)\z/s) {
        return (clip($1, MAX_TITLE), clip($2, MAX_DETAIL));
    }
    return (clip($text, MAX_TITLE), '');
}

sub cwe_of {
    my ($value) = @_;
    $value = $value->[0] if ref $value eq 'ARRAY';
    return undef unless defined $value && !ref $value;
    return "$value" =~ /\b(CWE-[0-9]{1,6})\b/i ? uc $1 : undef;
}

sub code_rule_finding {
    my ($ctx, $raw) = @_;
    return undef unless ref $raw eq 'HASH';
    my $extra = ref $raw->{extra} eq 'HASH' ? $raw->{extra} : {};
    my $meta = ref $extra->{metadata} eq 'HASH' ? $extra->{metadata} : {};
    my $id = defined $raw->{check_id} && !ref $raw->{check_id} ? "$raw->{check_id}" : 'rule';
    my $category = lc($meta->{category} // '');
    $category = 'hotspot' unless $category eq 'security' || $category eq 'hotspot';
    $category = 'sql' if $ctx->{kind} eq 'sql';
    my $severity = $IMPACT{ lc($meta->{impact} // '') } // $RULE_SEVERITY{ uc($extra->{severity} // '') } // 'medium';
    my ($title, $detail) = split_message($extra->{message});
    my $path = repo_path($ctx, $raw->{path});
    my $start = ref $raw->{start} eq 'HASH' ? $raw->{start} : {};
    my $end = ref $raw->{end} eq 'HASH' ? $raw->{end} : {};
    my $line = positive($start->{line});
    my $credential = $id =~ $CREDENTIAL_RULE;
    my $end_line = positive($end->{line}) // $line;
    return {
        category       => $category,
        tool           => $ctx->{engine} // q{opengrep},
        rule           => clip($id, MAX_RULE),
        severity       => $severity,
        path           => $path,
        line           => $line,
        title          => $title,
        detail         => $detail,
        recommendation => '',
        cwe            => cwe_of($meta->{cwe}),
        _rule_id       => $id,
        _span          => join("\0", $id, $path // '', map { $_ // '' } $start->{line}, $start->{col}, $end->{line}, $end->{col}),
        _column        => positive($start->{col}) // 0,
        _text          => $credential ? '' : undef,
        _hide          => $credential && defined $path && defined $line ? {
            path         => $path,
            line         => $line,
            end_line     => defined $end_line && $end_line >= $line ? $end_line : $line,
            start_column => positive($start->{col}),
            end_column   => positive($end->{col}),
        } : undef,
    };
}

my %TRIVY_SEVERITY = (CRITICAL => 'critical', HIGH => 'high', MEDIUM => 'medium', LOW => 'low');

sub trivy_tool {
    my ($ctx, $name, $why_skipped) = @_;
    my $tool = find_tool('trivy');
    my $version = $tool ? tool_version($tool->{path}, 'trivy') : undef;
    if ($why_skipped) {
        add_tool($ctx, $name, $version, 'skipped', $why_skipped);
        return;
    }
    if (!$tool) {
        add_tool($ctx, $name, undef, 'missing', missing_note('trivy'));
        return;
    }
    return ($tool, $version);
}

# Pieces of text as sentences: each ends with one full stop.
sub sentences {
    my ($parts) = @_;
    my @out;
    for my $part (@$parts) {
        (my $text = clip($part)) =~ s/[.\s]+\z//;
        push @out, "$text." if $text ne '';
    }
    return join(' ', @out);
}

sub trivy_skip_dirs { return map { ('--skip-dirs', "**/$_") } @SKIPPED_DIRS }

# Trivy's checks of infrastructure files: Dockerfiles, Terraform,
# Kubernetes, CloudFormation and Helm, from the checks built into Trivy,
# kept off the network.
sub run_trivy_config {
    my ($ctx) = @_;
    my ($tool, $version) = trivy_tool($ctx, 'trivy-config',
        $ctx->{mode} eq 'quick' ? 'full mode only: infrastructure files are checked in a full scan' : undef);
    return unless $tool;
    my $report = "$ctx->{raw}/trivy-config.json";
    my $err = "$ctx->{raw}/trivy-config.err";
    my $result = run_program(
        command => [
            $tool->{path}, 'config', '--skip-check-update', '--disable-telemetry', '--skip-version-check', '--cache-dir', "$ctx->{raw}/trivy-cache", '--format', 'json',
            '--output', $report, '--quiet', '--exit-code', '0', trivy_skip_dirs(), $ctx->{target},
        ],
        cwd => $ctx->{root}, env => tool_env($ctx, %NO_NETWORK), stderr => $err, timeout => scan_timeout(),
    );
    my $data = read_json($report, MAX_REPORT_RAW);
    my $why = first_error(read_bytes($err));
    unlink($report, $err);
    if (ref $data ne 'HASH') {
        add_tool($ctx, 'trivy-config', $version, 'failed',
            $result->{timed_out} ? 'ran out of time' : 'did not finish' . ($why ne '' ? ": $why" : " (exit $result->{status})"));
        return;
    }
    my @found;
    for my $target (ref $data->{Results} eq 'ARRAY' ? @{ $data->{Results} } : ()) {
        next unless ref $target eq 'HASH';
        for my $check (ref $target->{Misconfigurations} eq 'ARRAY' ? @{ $target->{Misconfigurations} } : ()) {
            next unless ref $check eq 'HASH' && ($check->{Status} // '') eq 'FAIL';
            push @found, trivy_config_finding($ctx, $target, $check);
        }
    }
    my $left = keep_visible($ctx, \@found);
    push @{ $ctx->{findings} }, @found;
    add_tool($ctx, 'trivy-config', $version, 'ran',
        join('; ', 'infrastructure files, offline', plural(scalar @found, 'finding'), $left ? "left out $left in files git ignores" : ()));
    return;
}

sub trivy_config_finding {
    my ($ctx, $target, $check) = @_;
    my $cause = ref $check->{CauseMetadata} eq 'HASH' ? $check->{CauseMetadata} : {};
    my $id = $check->{ID} // $check->{AVDID} // 'check';
    my @detail = grep { defined && !ref && /\S/ } $check->{Message}, $check->{Description};
    @detail = ($detail[0]) if @detail == 2 && $detail[0] eq $detail[1];
    push @detail, "More: $check->{PrimaryURL}" if defined $check->{PrimaryURL} && !ref $check->{PrimaryURL};
    return {
        category       => 'iac',
        tool           => 'trivy',
        rule           => clip("trivy:$id", MAX_RULE),
        severity       => $TRIVY_SEVERITY{ uc($check->{Severity} // '') } // 'info',
        path           => repo_path($ctx, $target->{Target}),
        line           => positive($cause->{StartLine}),
        title          => clip($check->{Title} || $check->{Message} || 'This file fails an infrastructure check.', MAX_TITLE),
        detail         => clip(sentences(\@detail), MAX_DETAIL),
        recommendation => clip($check->{Resolution}, MAX_DETAIL),
        cwe            => undef,
        _column        => 0,
    };
}

# Trivy's check of the dependencies the lock files name, against known
# vulnerabilities. Trivy downloads its vulnerability database for this, so
# it runs only in full mode, and a failure is reported, not fatal.
sub run_trivy_vuln {
    my ($ctx) = @_;
    my ($tool, $version) = trivy_tool($ctx, 'trivy-vuln',
        $ctx->{mode} eq 'quick' ? 'full mode only: dependency vulnerabilities are checked in a full scan, which downloads Trivy\'s database' : undef);
    return unless $tool;
    my $cache = $ENV{FLASHTEAMS_TRIVY_CACHE};
    my $report = "$ctx->{raw}/trivy-vuln.json";
    my $err = "$ctx->{raw}/trivy-vuln.err";
    my $result = run_program(
        command => [
            $tool->{path}, 'fs', '--scanners', 'vuln', '--disable-telemetry', '--skip-version-check', (defined $cache && $cache ne '' ? ('--cache-dir', $cache) : ()),
            '--format', 'json', '--output', $report, '--quiet', '--exit-code', '0', trivy_skip_dirs(), $ctx->{target},
        ],
        cwd => $ctx->{root}, env => tool_env($ctx), stderr => $err, timeout => scan_timeout(),
    );
    my $data = read_json($report, MAX_REPORT_RAW);
    my $why = first_error(read_bytes($err));
    unlink($report, $err);
    if (ref $data ne 'HASH') {
        add_tool($ctx, 'trivy-vuln', $version, 'failed',
            $result->{timed_out} ? 'ran out of time' : 'did not finish, often because its database could not be downloaded'
              . ($why ne '' ? ": $why" : " (exit $result->{status})"));
        return;
    }
    my @found;
    for my $target (ref $data->{Results} eq 'ARRAY' ? @{ $data->{Results} } : ()) {
        next unless ref $target eq 'HASH';
        for my $vuln (ref $target->{Vulnerabilities} eq 'ARRAY' ? @{ $target->{Vulnerabilities} } : ()) {
            next unless ref $vuln eq 'HASH';
            push @found, trivy_vuln_finding($ctx, $target, $vuln);
        }
    }
    my $left = keep_visible($ctx, \@found);
    push @{ $ctx->{findings} }, @found;
    add_tool($ctx, 'trivy-vuln', $version, 'ran',
        join('; ', 'dependency vulnerabilities', plural(scalar @found, 'finding'), $left ? "left out $left in files git ignores" : ()));
    return;
}

sub trivy_vuln_finding {
    my ($ctx, $target, $vuln) = @_;
    my $id = $vuln->{VulnerabilityID} // 'vulnerability';
    my $package = $vuln->{PkgName} // $vuln->{PkgID} // 'a dependency';
    my $installed = $vuln->{InstalledVersion} // '';
    my @detail = grep { defined && !ref && /\S/ } $vuln->{Title}, $vuln->{Description};
    push @detail, "More: $vuln->{PrimaryURL}" if defined $vuln->{PrimaryURL} && !ref $vuln->{PrimaryURL};
    my $fixed = $vuln->{FixedVersion};
    return {
        category       => 'dependency',
        tool           => 'trivy',
        rule           => clip("trivy:$id", MAX_RULE),
        severity       => $TRIVY_SEVERITY{ uc($vuln->{Severity} // '') } // 'info',
        path           => repo_path($ctx, $target->{Target}),
        line           => undef,
        title          => clip("$package $installed: $id", MAX_TITLE),
        detail         => clip(sentences(\@detail), MAX_DETAIL),
        recommendation => defined $fixed && !ref $fixed && $fixed ne '' ? clip("Upgrade to $fixed", MAX_DETAIL) : '',
        cwe            => cwe_of($vuln->{CweIDs}),
        _column        => 0,
        _text          => "$package\@$installed",
    };
}

# Reads source lines for fingerprints. Nothing it reads is kept.
sub line_reader {
    my ($root) = @_;
    my %cache;
    return sub {
        my ($path, $line) = @_;
        return '' unless defined $path && defined $line;
        if (!exists $cache{$path}) {
            my $bytes = read_bytes("$root/" . bytes_of($path), MAX_READ);
            $cache{$path} = defined $bytes ? [ split /\r?\n/, $bytes, -1 ] : [];
        }
        return chars($cache{$path}[ $line - 1 ] // '');
    };
}

sub sha32 {
    my ($text) = @_;
    return substr(Digest::SHA::sha256_hex(bytes_of($text)), 0, 32);
}

# Fingerprints that stay the same while a finding does: the category, the
# rule, the file and the flagged line's text with its spaces collapsed
# (nothing for a secret), and a number for repeats of the same line, so
# lines moving above it do not change it.
sub add_fingerprints {
    my ($findings, $text_of) = @_;
    my %seen;
    my @ordered = sort {
        ($a->{path} // '') cmp ($b->{path} // '') || ($a->{line} // 0) <=> ($b->{line} // 0)
          || ($a->{_column} // 0) <=> ($b->{_column} // 0) || $a->{rule} cmp $b->{rule}
    } @$findings;
    for my $finding (@ordered) {
        my $text = $finding->{_text} // $text_of->($finding->{path}, $finding->{line});
        $text =~ s/\s+/ /g;
        $text =~ s/\A //;
        $text =~ s/ \z//;
        my $base = join("\n", $finding->{category}, $finding->{rule}, $finding->{path} // '', $text);
        my $occurrence = $seen{$base}++ // 0;
        $finding->{fingerprint} = sha32("$base\n$occurrence");
    }
    return;
}

sub by_severity {
    return $SEVERITY_RANK{ $a->{severity} } <=> $SEVERITY_RANK{ $b->{severity} }
      || ($a->{path} // '') cmp ($b->{path} // '')
      || ($a->{line} // 0) <=> ($b->{line} // 0)
      || $a->{rule} cmp $b->{rule}
      || $a->{title} cmp $b->{title}
      || $a->{fingerprint} cmp $b->{fingerprint};
}

sub finish_findings {
    my ($ctx) = @_;
    my @findings = @{ $ctx->{findings} };
    add_fingerprints(\@findings, line_reader($ctx->{root}));
    return sort by_severity @findings;
}

sub location {
    my ($finding) = @_;
    return '(repository)' unless defined $finding->{path};
    return $finding->{path} . (defined $finding->{line} ? ":$finding->{line}" : '');
}

sub counts_of {
    my ($findings) = @_;
    my %count = map { $_ => 0 } @SEVERITIES;
    $count{ $_->{severity} }++ for @$findings;
    return \%count;
}

sub print_summary {
    my ($ctx, $out, $rules_version, $findings) = @_;
    my $what = $ctx->{kind} eq 'sql' ? 'SQL scan' : "security scan ($ctx->{mode} mode)";
    print "FlashTeams $what of " . path_label($ctx->{path}) . "\n";
    print 'Work folder: ' . chars($out) . "\n";
    print 'Rules: ' . (defined $rules_version ? "FlashTeams rules $rules_version" : 'FlashTeams rules not downloaded') . "\n";
    print "Tools:\n";
    for my $tool (@{ $ctx->{tools} }) {
        print "  $tool->{name}" . (defined $tool->{version} ? " $tool->{version}" : '') . ": $tool->{status}"
          . ($tool->{note} ne '' ? ". $tool->{note}" : '') . "\n";
    }
    my $count = counts_of($findings);
    print 'Findings: ' . scalar(@$findings) . ' (' . join(', ', map { "$_ $count->{$_}" } @SEVERITIES) . ")\n";
    my %category;
    $category{ $_->{category} }++ for @$findings;
    print 'By category: ' . join(', ', map { "$_ $category{$_}" } grep { $category{$_} } @CATEGORIES) . "\n" if @$findings;
    my $shown = @$findings < SUMMARY_TOP ? @$findings : SUMMARY_TOP;
    for my $i (0 .. $shown - 1) {
        my $finding = $findings->[$i];
        print '#' . ($i + 1) . " $finding->{severity} $finding->{category} " . location($finding) . " $finding->{title} ($finding->{rule})\n";
    }
    print "Showing the $shown most severe of " . scalar(@$findings) . '. Every finding is in ' . chars("$out/findings.json") . "\n"
      if @$findings > $shown;
    print qq{See findings in full with their code: perl "} . chars($SELF) . qq{" show --out "} . chars($out) . qq{" --ids 1,2,3\n}
      if @$findings;
    return;
}

# ---------------------------------------------------------------------------
# show: findings in full, with the code around them.

sub load_work {
    my ($out) = @_;
    fail(2, '--out is required') unless defined $out && $out ne '';
    my $dir = abs_path($out);
    fail(1, "$out is not a work folder") unless defined $dir && -d $dir;
    my $scan = read_json("$dir/scan.json", 16 * 1024 * 1024);
    my $findings = read_json("$dir/findings.json", MAX_REPORT_RAW);
    my $hidden = read_json("$dir/hidden.json", MAX_REPORT_RAW);
    return {
        dir      => $dir,
        scan     => ref $scan eq 'HASH' ? $scan : undef,
        findings => ref $findings eq 'ARRAY' ? $findings : undef,
        hidden   => ref $hidden eq 'HASH' ? $hidden : {},
    };
}

sub cmd_show {
    my $opt = options('show', \@_, 'out=s', 'ids=s', 'context=i');
    my $work = load_work($opt->{out});
    fail(1, "There is no scan in $opt->{out}. Run the scan first.") unless $work->{scan} && $work->{findings};
    my @ids = grep { $_ ne '' } split /[\s,#]+/, $opt->{ids} // '';
    fail(2, 'show: --ids lists the finding numbers, such as 3,12,40') unless @ids;
    my $context = $opt->{context} // 4;
    $context = 0 if $context < 0;
    $context = 30 if $context > 30;
    my $root = bytes_of($work->{scan}{root} // '');
    my $findings = $work->{findings};
    for my $id (@ids) {
        if ($id !~ /\A[0-9]+\z/ || $id < 1 || $id > @$findings) {
            print "#$id: there is no such finding; they run from #1 to #" . scalar(@$findings) . ".\n\n";
            next;
        }
        show_finding($root, $work, $id, $context);
    }
    return 0;
}

# The lines of a file to print in place of what they hold: each hidden
# finding's lines, with the matched part (or the whole line) as [hidden].
sub hidden_lines {
    my ($work, $path, $lines) = @_;
    my %spans;
    for my $hide (values %{ $work->{hidden} }) {
        next unless ref $hide eq 'HASH' && defined $hide->{path} && $hide->{path} eq $path && positive($hide->{line});
        my $first = $hide->{line};
        my $last = positive($hide->{end_line}) // $first;
        $last = $first if $last < $first || $last > $first + 200;
        my $from = $first == $last ? positive($hide->{start_column}) : undef;
        push @{ $spans{$_} }, $from for $first .. $last;
    }
    my %replace;
    for my $n (keys %spans) {
        my $text = $lines->[ $n - 1 ];
        next unless defined $text;
        # One finding on the line, with a known start: the line before the
        # match stays, and everything from one column before it on is
        # hidden, so a column counted one off (gitleaks counts one past the
        # start on every line but the first) can only hide more. A start
        # that falls inside a word moves back to the word's start. Otherwise
        # the whole line goes.
        my @starts = @{ $spans{$n} };
        my $from = @starts == 1 ? $starts[0] : undef;
        if (defined $from && $from <= length($text) + 1) {
            my $keep = $from > 1 ? $from - 2 : 0;
            my $word = qr{[A-Za-z0-9_+/=-]};
            $keep-- while $keep > 0 && substr($text, $keep, 1) =~ $word && substr($text, $keep - 1, 1) =~ $word;
            $replace{$n} = substr($text, 0, $keep) . hidden_mark(substr($text, $keep));
        }
        else {
            $replace{$n} = hidden_mark($text);
        }
    }
    return \%replace;
}

# What stands in for a secret: [hidden], and whether the hidden text has a
# placeholder's words (example, test, changeme, your_...), so a made-up
# value can be told from a real one without seeing it.
sub hidden_mark {
    my ($value) = @_;
    return $value =~ $MADE_UP ? '[hidden, has placeholder words]' : '[hidden]';
}

# A line of code as it is printed: no control characters, no marks that
# reorder text, at most 300 characters.
sub printable_line {
    my ($text) = @_;
    $text = chars($text);
    $text =~ s/[\x00-\x08\x0a-\x1f\x7f\x{061c}\x{200e}\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}]/?/g;
    $text = substr($text, 0, 299) . "\x{2026}" if length($text) > 300;
    return $text;
}

sub show_finding {
    my ($root, $work, $id, $context) = @_;
    my $finding = $work->{findings}[ $id - 1 ];
    print "#$id $finding->{severity} $finding->{category} " . location($finding) . "\n";
    print "  Title: $finding->{title}\n";
    print "  Rule: $finding->{rule} ($finding->{tool})\n";
    print "  CWE: $finding->{cwe}\n" if defined $finding->{cwe};
    print "  Detail: $finding->{detail}\n" if ($finding->{detail} // '') ne '';
    print "  Fix: $finding->{recommendation}\n" if ($finding->{recommendation} // '') ne '';
    print "  Fingerprint: $finding->{fingerprint}\n";
    if (!defined $finding->{path} || !defined $finding->{line}) {
        print "  (This finding is about the whole file, not one line.)\n\n";
        return;
    }
    my $file = "$root/" . bytes_of($finding->{path});
    my $bytes = -f $file ? read_bytes($file, MAX_READ) : undef;
    if (!defined $bytes) {
        print -f $file ? "  (The file is too large to show.)\n\n" : "  (The file is not in the working tree now.)\n\n";
        return;
    }
    if (index(substr($bytes, 0, 8192), "\0") >= 0) {
        print "  (The file is binary.)\n\n";
        return;
    }
    my @lines = split /\r?\n/, $bytes, -1;
    pop @lines if @lines && $lines[-1] eq '';
    my $hidden = hidden_lines($work, $finding->{path}, \@lines);
    my $last = $finding->{line};
    if (my $hide = $work->{hidden}{$id}) {
        $last = $hide->{end_line} if positive($hide->{end_line}) && $hide->{end_line} > $last && $hide->{end_line} < $last + 200;
    }
    my $from = $finding->{line} - $context;
    $from = 1 if $from < 1;
    my $to = $last + $context;
    $to = @lines if $to > @lines;
    if ($finding->{line} > @lines) {
        print "  (The file has fewer lines now; it changed since the scan.)\n\n";
        return;
    }
    print "  Code:\n";
    for my $n ($from .. $to) {
        my $text = exists $hidden->{$n} ? $hidden->{$n} : $lines[ $n - 1 ];
        my $mark = $n >= $finding->{line} && $n <= $last ? '>' : ' ';
        printf "  %s%6d | %s\n", $mark, $n, printable_line($text);
    }
    print "\n";
    return;
}

# ---------------------------------------------------------------------------
# payload: the scan as record_code_scan takes it.

# origin's address with any user name, password, query or fragment taken
# out. An address that names a folder on this computer is left out.
sub clean_remote_url {
    my ($url) = @_;
    return undef unless defined $url && !ref $url;
    $url =~ s/\A\s+//;
    $url =~ s/\s+\z//;
    return undef if $url eq '' || $url =~ m{\A(?:file:|/|\\|\.|~|[A-Za-z]:[\\/])}i;
    if ($url =~ m{\A([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)(.*)\z}s) {
        my ($scheme, $authority, $rest) = (lc $1, $2, $3);
        $authority =~ s/\A.*@//s;
        $rest =~ s/[?#].*\z//s;
        return undef if $authority eq '';
        return "$scheme://$authority$rest";
    }
    my ($head) = $url =~ m{\A([^/]*)};
    if ($head =~ /@/) {
        my $at = rindex($head, '@');
        $url = substr($url, $at + 1);
        $head = substr($head, $at + 1);
    }
    return $url if $head =~ /\A[A-Za-z0-9._-]+:/ && $url =~ m{\A[^:]+:.+\z}s;
    return undef;
}

sub repository_facts {
    my ($root, $path) = @_;
    my $url = git_line($root, 'config', '--get', 'remote.origin.url');
    my $branch = git_line($root, 'symbolic-ref', '--short', '-q', 'HEAD');
    my $commit = git_line($root, 'rev-parse', '-q', '--verify', 'HEAD^{commit}');
    my $status = git($root, 'status', '--porcelain', '--', $path eq '' ? '.' : bytes_of($path));
    return {
        remote_url => clean_remote_url($url),
        branch     => defined $branch && $branch ne '' ? $branch : undef,
        commit     => defined $commit && $commit =~ /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/ ? $commit : undef,
        dirty      => $status->{status} != 0 || $status->{stdout} =~ /\S/ ? JSON::PP::true : JSON::PP::false,
    };
}

sub read_text_file {
    my ($path, $what) = @_;
    fail(2, "payload: --$what is required") unless defined $path && $path ne '';
    my $bytes = read_bytes($path, 16 * 1024 * 1024);
    fail(1, 'payload: cannot read the ' . chars("$what $path")) unless defined $bytes;
    my $text = chars($bytes);
    $text =~ s/\r\n?/\n/g;
    $text =~ s/[\x00-\x08\x0b-\x1f\x7f]//g;
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;
    fail(1, 'payload: the ' . chars("$what $path") . ' is empty') if $text eq '';
    return $text;
}

# Text cut to at most a number of characters, ending with a note when cut.
sub cut_chars {
    my ($text, $max) = @_;
    return ($text, 0) if length($text) <= $max;
    my $note = " [Cut to fit FlashTeams' limit.]";
    return (substr($text, 0, $max - length($note)) . $note, 1);
}

# Text cut to at most a number of bytes of UTF-8, at the end of a character,
# ending with a note when cut. The report travels as one argument of the
# flashteams command, and Linux takes at most 128 KB in one.
sub cut_bytes {
    my ($text, $max) = @_;
    my $bytes = bytes_of($text);
    return ($text, 0) if length($bytes) <= $max;
    my $note = "\n\n[The rest of the report was cut to fit FlashTeams' limit.]";
    my $head = substr($bytes, 0, $max - length($note));
    my $whole = Encode::decode('UTF-8', $head, Encode::FB_QUIET);
    return ($whole . $note, 1);
}

# Takes this computer's folders out of what the agent wrote: a path in the
# repository becomes the path inside it, the repository's own folder its
# name, and the home folder ~.
sub without_local_paths {
    my ($text, $root) = @_;
    return $text unless defined $text && $text ne '';
    my $home = chars(home());
    $root = chars($root);
    if (length($root) > 1) {
        my $name = basename($root);
        $text =~ s{\Q$root\E/}{}g;
        $text =~ s{\Q$root\E}{$name}g;
    }
    $text =~ s{\Q$home\E(?=/|\b)}{~}g if length($home) > 1;
    return $text;
}

sub note_text {
    my ($value, $max, $what) = @_;
    return '' unless defined $value;
    fail(1, "payload: the notes' $what is not text") if ref $value;
    my $text = "$value";
    $text =~ s/\r\n?/\n/g;
    $text =~ s/[\x00-\x09\x0b-\x1f\x7f]+/ /g;
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;
    $text = substr($text, 0, $max - 1) . "\x{2026}" if length($text) > $max;
    return $text;
}

sub note_path {
    my ($value) = @_;
    return undef unless defined $value && $value ne '';
    fail(1, 'payload: a path in the notes is not text') if ref $value;
    (my $path = "$value") =~ s{\\}{/}g;
    $path =~ s{\A(?:\./)+}{};
    fail(1, "payload: the notes name the path $value; give it relative to the repository root, without ..")
      if $path =~ m{\A/} || $path =~ m{\A[A-Za-z]:} || grep { $_ eq '..' } split m{/}, $path;
    return $path;
}

# The agent's notes: findings to dismiss, words for some, and findings of
# its own.
sub apply_notes {
    my ($findings, $notes_file, $root) = @_;
    my @kept = @$findings;
    my (@added, %dismissed);
    return (\@kept, 0, 0) unless defined $notes_file && $notes_file ne '';
    my $notes = read_json($notes_file, 16 * 1024 * 1024);
    fail(1, "payload: the notes $notes_file are not a JSON object") unless ref $notes eq 'HASH';
    my %known = map { $_ => 1 } qw(dismiss notes add);
    my @unknown = grep { !$known{$_} } sort keys %$notes;
    fail(1, "payload: the notes have keys this does not read: @unknown (use dismiss, notes and add)") if @unknown;
    my $total = @$findings;
    my $check_id = sub {
        my ($id) = @_;
        fail(1, "payload: the notes name finding $id, but the scan has findings #1 to #$total")
          unless defined $id && !ref $id && $id =~ /\A#?([0-9]+)\z/ && $1 >= 1 && $1 <= $total;
        return $id =~ s/\A#//r;
    };
    if (defined $notes->{dismiss}) {
        fail(1, 'payload: dismiss is a list of finding numbers') unless ref $notes->{dismiss} eq 'ARRAY';
        $dismissed{ $check_id->($_) } = 1 for @{ $notes->{dismiss} };
    }
    if (defined $notes->{notes}) {
        fail(1, 'payload: notes is an object of finding numbers') unless ref $notes->{notes} eq 'HASH';
        for my $key (sort keys %{ $notes->{notes} }) {
            my $id = $check_id->($key);
            my $note = $notes->{notes}{$key};
            fail(1, "payload: the note for $key is not an object") unless ref $note eq 'HASH';
            my %copy = %{ $kept[ $id - 1 ] };
            $copy{detail} = without_local_paths(note_text($note->{detail}, MAX_DETAIL, 'detail'), $root) if defined $note->{detail};
            $copy{recommendation} = without_local_paths(note_text($note->{recommendation}, MAX_DETAIL, 'recommendation'), $root)
              if defined $note->{recommendation};
            $kept[ $id - 1 ] = \%copy;
        }
    }
    if (defined $notes->{add}) {
        fail(1, 'payload: add is a list of findings') unless ref $notes->{add} eq 'ARRAY';
        my %seen;
        for my $i (0 .. $#{ $notes->{add} }) {
            my $add = $notes->{add}[$i];
            my $which = 'added finding ' . ($i + 1);
            fail(1, "payload: the $which is not an object") unless ref $add eq 'HASH';
            my $category = $add->{category} // '';
            fail(1, "payload: the $which has category '$category'; use one of @CATEGORIES") unless $CATEGORY{$category};
            my $severity = $add->{severity} // '';
            fail(1, "payload: the $which has severity '$severity'; use one of @SEVERITIES") unless defined $SEVERITY_RANK{$severity};
            my $title = without_local_paths(clip(note_text($add->{title}, MAX_TITLE, 'title'), MAX_TITLE), $root);
            fail(1, "payload: the $which has no title") if $title eq '';
            my $path = note_path($add->{path});
            my $line = $add->{line};
            fail(1, "payload: the $which has line '$line'; give a number from 1, or leave it out")
              if defined $line && !positive($line);
            my $rule = clip(note_text($add->{rule} // "agent.$category", MAX_RULE, 'rule'), MAX_RULE);
            $rule = "agent.$category" if $rule eq '';
            my $cwe = cwe_of($add->{cwe});
            my $base = join("\n", $rule, $path // '', $title);
            my $occurrence = $seen{$base}++ // 0;
            push @added, {
                fingerprint    => sha32($occurrence ? "$base\n$occurrence" : $base),
                category       => $category,
                tool           => 'agent',
                rule           => $rule,
                severity       => $severity,
                path           => $path,
                line           => positive($line),
                title          => $title,
                detail         => without_local_paths(note_text($add->{detail}, MAX_DETAIL, 'detail'), $root),
                recommendation => without_local_paths(note_text($add->{recommendation}, MAX_DETAIL, 'recommendation'), $root),
                cwe            => $cwe,
            };
        }
    }
    my @left = map { $kept[$_] } grep { !$dismissed{ $_ + 1 } } 0 .. $#kept;
    return ([ @left, @added ], scalar(keys %dismissed), scalar(@added));
}

# One finding exactly as the payload carries it, its words without this
# computer's folders.
sub payload_finding {
    my ($finding, $root) = @_;
    my %out = map { $_ => $finding->{$_} } qw(fingerprint category tool rule severity path line title detail recommendation cwe);
    $out{line} = defined $out{line} ? 0 + $out{line} : undef;
    $out{$_} = without_local_paths($out{$_} // '', $root) for qw(title detail recommendation);
    return \%out;
}

# One tool as the payload carries it. A note can quote a scanner's error,
# which can name a folder of this computer.
sub payload_tool {
    my ($tool, $root) = @_;
    return {
        name    => $tool->{name},
        version => $tool->{version},
        status  => $tool->{status},
        note    => without_local_paths($tool->{note} // '', $root),
    };
}

sub cmd_payload {
    my $opt = options('payload', \@_, 'out=s', 'kind=s', 'mode=s', 'path=s', 'summary-file=s', 'report-file=s', 'notes=s',
        'max-findings=i', 'max-report-bytes=i');
    $opt->{path} = chars($opt->{path}) if defined $opt->{path};
    my $kind = $opt->{kind} // '';
    fail(2, 'payload: --kind is security, sql or architecture') unless $kind =~ /\A(?:security|sql|architecture)\z/;
    fail(2, 'payload: --out is required') unless defined $opt->{out} && $opt->{out} ne '';
    make_path($opt->{out}) if $kind eq 'architecture';
    my $work = load_work($opt->{out});
    my $scan = $work->{scan};
    $scan = undef if $kind eq 'architecture' && $scan && ($scan->{kind} // '') ne 'architecture';
    if ($kind ne 'architecture') {
        fail(1, "payload: there is no $kind scan in " . chars($opt->{out}) . '; run it first') unless $scan && $work->{findings};
        fail(1, 'payload: the scan in ' . chars($opt->{out}) . " is a $scan->{kind} scan, not $kind") unless ($scan->{kind} // '') eq $kind;
    }
    my $root = $scan && defined $scan->{root} && -d bytes_of($scan->{root}) ? bytes_of($scan->{root}) : repo_root();

    my $mode;
    if ($kind ne 'architecture') {
        $mode = $opt->{mode} // $scan->{mode};
        fail(2, 'payload: --mode is quick or full') unless defined $mode && $mode =~ /\A(?:quick|full)\z/;
        fail(1, "payload: the scan ran in $scan->{mode} mode, not $mode") if ($scan->{mode} // $mode) ne $mode;
    }
    my $path = scan_path($opt->{path} // ($scan ? $scan->{path} : '') // '', $root);
    fail(1, 'payload: the scan was of ' . path_label($scan->{path} // '') . ', not ' . path_label($path))
      if $scan && ($scan->{path} // '') ne $path;

    my $report_bytes = $opt->{'max-report-bytes'} // MAX_REPORT;
    $report_bytes = MAX_REPORT if $report_bytes > MAX_REPORT || $report_bytes < 1000;
    my ($summary, $summary_cut) = cut_chars(without_local_paths(read_text_file($opt->{'summary-file'}, 'summary-file'), $root), MAX_SUMMARY);
    my ($report, $report_cut) = cut_bytes(without_local_paths(read_text_file($opt->{'report-file'}, 'report-file'), $root), $report_bytes);
    my $scanned = $kind eq 'architecture' ? [] : $work->{findings};
    my ($findings, $dismissed, $added) = apply_notes($scanned, $opt->{notes}, $root);
    my @sorted = sort by_severity map { payload_finding($_, $root) } @$findings;
    my $max = $opt->{'max-findings'} // MAX_FINDINGS;
    $max = MAX_FINDINGS if $max > MAX_FINDINGS || $max < 0;
    my $truncated = @sorted > $max ? @sorted - $max : 0;
    splice(@sorted, $max) if $truncated;

    my $tools = $kind eq 'architecture' ? [] : read_json("$work->{dir}/tools.json", 16 * 1024 * 1024);
    my $payload = {
        kind           => $kind,
        mode           => $mode,
        repository     => repository_facts($root, $path),
        scanned_path   => $path,
        rules_version  => $kind eq 'architecture' ? undef : $scan->{rules_version},
        tools          => ref $tools eq 'ARRAY' ? [ map { payload_tool($_, $root) } @$tools ] : [],
        summary        => $summary,
        report_markdown => $report,
        findings       => \@sorted,
        truncated      => 0 + $truncated,
    };
    my $file = "$work->{dir}/payload.json";
    write_bytes($file, json_codec()->encode($payload));
    my $count = counts_of(\@sorted);
    print chars($file), "\n";
    print scalar(@sorted) . ' findings (' . join(', ', map { "$_ $count->{$_}" } @SEVERITIES) . ")"
      . ($dismissed ? ", $dismissed dismissed" : '') . ($added ? ", $added added" : '')
      . ($truncated ? ", $truncated less severe left out (truncated)" : '') . "\n";
    print "The summary was cut to " . MAX_SUMMARY . " characters.\n" if $summary_cut;
    print "The report was cut to $report_bytes bytes.\n" if $report_cut;
    return 0;
}

# ---------------------------------------------------------------------------
# send: the payload to FlashTeams, through the flashteams command.

# The flashteams command that Flash Console provides: FLASHTEAMS_BIN when it
# names one by its full path, else the PATH, else Flash Console's own folder
# (FLASH_CONSOLE_BIN). Fails with exit 3, as the command does when Flash
# Console is not there.
sub flashteams_program {
    my $given = $ENV{FLASHTEAMS_BIN};
    if (defined $given && $given ne '') {
        return $given if File::Spec->file_name_is_absolute($given) && -f $given && -x _;
        fail(3, 'FLASHTEAMS_BIN does not name the flashteams command by its full path: ' . chars($given));
    }
    my $found = on_path('flashteams');
    return $found if $found;
    my $folder = $ENV{FLASH_CONSOLE_BIN};
    if (defined $folder && File::Spec->file_name_is_absolute($folder)) {
        for my $program (program_names('flashteams')) {
            return "$folder/$program" if -f "$folder/$program" && -x _;
        }
    }
    fail(3, 'The flashteams command is not here. Flash Console provides it; without it, use the FlashTeams MCP tools, '
          . 'or keep the report on this computer.');
}

# The payload's fields as the flashteams command's arguments, each one
# argument of its own as --name=value: text as it is, the repository and
# the tools as compact JSON, numbers as numbers, and mode and rules_version
# left out when they are empty. The findings go on standard input.
sub send_arguments {
    my ($payload, %extra) = @_;
    my @args = ('record_code_scan');
    for my $key (qw(kind mode repository scanned_path rules_version tools summary report_markdown truncated)) {
        my $value = $payload->{$key};
        next unless defined $value;
        push @args, "--$key=" . (ref $value ? json_codec()->encode($value) : bytes_of("$value"));
    }
    for my $key (sort keys %extra) {
        push @args, "--$key=" . bytes_of($extra{$key}) if defined $extra{$key} && $extra{$key} ne '';
    }
    # The command then prints the tool's own JSON answer, as the agent reads it.
    push @args, '--findings', '-';
    return @args;
}

sub cmd_send {
    my $opt = options('send', \@_, 'out=s', 'product-id=s', 'organization-id=s');
    fail(2, 'send: --out is required') unless defined $opt->{out} && $opt->{out} ne '';
    my $file = "$opt->{out}/payload.json";
    my $payload = read_json($file, 64 * 1024 * 1024);
    fail(1, 'send: there is no payload in ' . chars($opt->{out}) . '; build it first with payload') unless ref $payload eq 'HASH';
    fail(1, 'send: the payload has no findings list; build it again with payload') unless ref $payload->{findings} eq 'ARRAY';
    for my $id (grep { defined } $opt->{'product-id'}, $opt->{'organization-id'}) {
        fail(2, "send: $id is not an id") unless $id =~ /\A[A-Za-z0-9_-]{1,100}\z/;
    }
    my $program = flashteams_program();
    my @args = send_arguments($payload, product_id => $opt->{'product-id'}, organization_id => $opt->{'organization-id'});
    if (is_windows()) {
        my $length = 0;
        $length += length($_) + 3 for $program, @args;
        fail(2, "send: Windows takes at most 32,767 characters on one command line, and this one is $length. "
              . 'Build the payload again with a shorter report (payload --max-report-bytes 20000).')
          if $length > 32000;
    }
    my $input = scratch() . '/findings.json';
    write_bytes($input, json_codec()->encode($payload->{findings}));
    # The command's answer reaches the agent as it is, and so does its exit
    # code: 0 done, 1 refused (the answer says why), 3 Flash Console not
    # reachable, 4 agents off, 5 busy or the network failed. Never sent twice.
    my $result = run_program(command => [ $program, @args ], stdin => $input, keep_output => 1, timeout => 900);
    unlink($input);
    if ($result->{timed_out}) {
        print STDERR "flashteams-scan: the flashteams command took too long. The scan may have been recorded; check before sending again.\n";
        return 5;
    }
    return $result->{status};
}

# Last, so every table above is filled in before main runs. Loaded as a
# library (by the tests), it runs nothing.
exit main(@ARGV) unless caller;
