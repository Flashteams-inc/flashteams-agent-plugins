#!/usr/bin/perl
# Tests the scan helper that the audit skills run
# (shared/scan/flashteams-scan.pl), without the network. Stand-ins for
# gitleaks, opengrep, semgrep, Trivy, curl and the flashteams command write
# reports shaped like the real ones, and the helper runs inside git
# repositories this test makes. It checks:
#
#   - doctor: what it finds, where, and the exact install choices;
#   - install: Windows refused, a download that fails its checksum
#     installs nothing, and the pins themselves;
#   - rules: the checksum, the format, paths that would leave the folder,
#     the cache, and asking FlashTeams through the flashteams command;
#   - run: each scanner's findings as one list (categories, severities,
#     titles, CWE), files git ignores left out, the SQL audit's filters,
#     a missing scanner, semgrep in place of opengrep, no rules, and
#     fingerprints that stay put when lines move but differ for repeats;
#   - show: the code around a finding, with a secret as [hidden];
#   - payload: the exact fields, git's facts (no user name or password in
#     the remote, dirty, detached, no commits), the notes, the cap of 500,
#     the summary and report caps, and no folder of this computer;
#   - send: every field as an argument, the findings on standard input,
#     and the flashteams command's answer and exit code passed on;
#   - that no secret's value appears in any file the helper wrote or
#     anything it printed.

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use Digest::SHA qw(sha256_hex);
use Encode ();
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use FindBin;
use IPC::Open3 qw(open3);
use JSON::PP;
use Symbol qw(gensym);
use Test::More;

our $HELPER = abs_path("$FindBin::Bin/../shared/scan/flashteams-scan.pl");
my $TMP = abs_path(tempdir('ftscan-XXXXXX', TMPDIR => 1, CLEANUP => 1));
my $JSON = JSON::PP->new->utf8->canonical;

{
    package Scan;
    do $main::HELPER;
}
die "cannot load the helper: $@" if $@;
ok(defined &Scan::cmd_run, 'the helper loads as a library and runs nothing');

# Secret values, made here so no literal key sits in this file.
my @BASE32 = ('A' .. 'Z', 2 .. 7);
my $SECRET = 'AKIA' . join('', map { $BASE32[ ($_ * 11 + 3) % 32 ] } 1 .. 16);
my $SECRET2 = 'zq' . join('', map { $BASE32[ ($_ * 5 + 1) % 32 ] } 1 .. 30);
my $PASSWORD = 'Pw' . join('', map { $BASE32[ ($_ * 3 + 7) % 32 ] } 1 .. 12);

sub write_file {
    my ($path, $text, $mode) = @_;
    (my $dir = $path) =~ s{/[^/]+\z}{};
    make_path($dir);
    open(my $fh, '>:raw', $path) or die "$path: $!";
    print {$fh} $text;
    close($fh) or die "$path: $!";
    chmod($mode, $path) if defined $mode;
    return;
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    return scalar <$fh>;
}

sub json_file { my $bytes = slurp($_[0]); return defined $bytes ? $JSON->decode($bytes) : undef }
sub write_json { write_file($_[0], $JSON->encode($_[1])) }

sub system_quiet {
    my ($dir, @command) = @_;
    my $here = getcwd();
    chdir($dir) or die "$dir: $!";
    my $pid = open3(my $in, my $out, undef, @command);
    close($in);
    my $output = do { local $/; <$out> } // '';
    waitpid($pid, 0);
    chdir($here) or die "$here: $!";
    die "@command failed in $dir: $output" if $?;
    return $output;
}

my @GIT = ('git', '-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false',
    '-c', 'init.defaultBranch=main');
sub git { my ($dir, @args) = @_; return system_quiet($dir, @GIT, @args) }

# The programs the helper may run besides the stand-ins, linked into one
# folder, so a real scanner installed on this computer is never found.
my $SYSBIN = "$TMP/sysbin";
make_path($SYSBIN);
for my $name (qw(git curl tar gzip cat cp mv rm mkdir date env sed tr uname printf)) {
    my ($found) = grep { -x "$_/$name" && !-d "$_/$name" } split /:/, $ENV{PATH};
    symlink("$found/$name", "$SYSBIN/$name") if $found;
}

my $FIXTURES = "$TMP/fixtures";
my $FAKES = "$TMP/fakes";
make_path($FIXTURES, $FAKES, "$TMP/home", "$TMP/tmp", "$TMP/no-tools");

my %FAKE = (
    gitleaks => <<'EOF',
#!/bin/sh
if [ "$1" = version ]; then echo 8.30.1; exit 0; fi
printf 'gitleaks %s\n' "$*" >> "$FAKE_LOG"
out= config=
while [ $# -gt 0 ]; do
  case $1 in
    --report-path) out=$2; shift ;;
    --config) config=$2; shift ;;
  esac
  shift
done
if [ -n "$config" ]; then cp "$FAKE_FIXTURES/gitleaks-flashteams.json" "$out"; else cp "$FAKE_FIXTURES/gitleaks-default.json" "$out"; fi
EOF
    opengrep => <<'EOF',
#!/bin/sh
if [ "$1" = --version ]; then echo 1.30.0; exit 0; fi
printf 'opengrep %s\n' "$*" >> "$FAKE_LOG"
out=
for arg in "$@"; do case $arg in --json-output=*) out=${arg#--json-output=} ;; esac; done
case "$*" in
  */opengrep/sql*) cp "$FAKE_FIXTURES/opengrep-sql.json" "$out" ;;
  *) cp "$FAKE_FIXTURES/opengrep-security.json" "$out" ;;
esac
echo "a code line the text output would print: CODE-ON-STDOUT"
EOF
    trivy => <<'EOF',
#!/bin/sh
if [ "$1" = --version ]; then printf 'Version: 0.74.0\nVulnerability DB:\n'; exit 0; fi
printf 'trivy %s proxy=%s\n' "$*" "${HTTPS_PROXY:-}" >> "$FAKE_LOG"
sub=$1
out=
while [ $# -gt 0 ]; do case $1 in --output) out=$2; shift ;; esac; shift; done
case $sub in
  config) cp "${FAKE_TRIVY_CONFIG:-$FAKE_FIXTURES/trivy-config.json}" "$out" ;;
  fs)
    if [ -n "${FAKE_TRIVY_FS_FAIL:-}" ]; then echo "FATAL failed to download vulnerability DB" >&2; exit 1; fi
    cp "$FAKE_FIXTURES/trivy-vuln.json" "$out" ;;
esac
EOF
    flashteams => <<'EOF',
#!/bin/sh
: > "$FAKE_FT_ARGS"
for arg in "$@"; do printf '%s\0' "$arg" >> "$FAKE_FT_ARGS"; done
cat > "$FAKE_FT_STDIN"
if [ "$1" = get_scan_rules ]; then cat "$FAKE_FT_RULES_ANSWER"; else cat "$FAKE_FT_ANSWER"; fi
echo "a note on stderr" >&2
exit "${FAKE_FT_EXIT:-0}"
EOF
    curl => <<'EOF',
#!/bin/sh
printf 'curl %s\n' "$*" >> "$FAKE_LOG"
out=
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; esac; shift; done
printf 'not the program you asked for' > "$out"
EOF
    brew => "#!/bin/sh\nexit 0\n",
);
$FAKE{semgrep} = $FAKE{opengrep} =~ s/echo 1\.30\.0/echo 1.99.0/r =~ s/opengrep %s/semgrep %s/r;

# Folders of stand-ins, each with the scanners named.
sub fakes {
    my ($name, @tools) = @_;
    my $dir = "$FAKES/$name";
    make_path($dir);
    write_file("$dir/$_", $FAKE{$_}, 0755) for @tools;
    return $dir;
}
my $ALL = fakes('all', qw(gitleaks opengrep trivy flashteams));

my @OUTPUTS;    # everything the helper printed, checked for secrets at the end

# Runs the helper as the skills do, with only the stand-ins and the
# linked system programs on the PATH.
sub helper {
    my (%opt) = @_;
    my %env = (
        PATH                 => join(':', $opt{fakes} // $ALL, $SYSBIN),
        HOME                 => "$TMP/home",
        TMPDIR               => "$TMP/tmp",
        FLASHTEAMS_TOOLS_DIR => "$TMP/no-tools",
        FLASHTEAMS_RULES_DIR => "$TMP/rules-cache",
        FAKE_LOG             => "$TMP/fake.log",
        FAKE_FIXTURES        => $FIXTURES,
        FAKE_FT_ARGS         => "$TMP/ft-args",
        FAKE_FT_STDIN        => "$TMP/ft-stdin",
        FAKE_FT_ANSWER       => "$TMP/ft-answer",
        FAKE_FT_RULES_ANSWER => "$TMP/ft-rules-answer",
        GIT_CONFIG_NOSYSTEM  => 1,
        %{ $opt{env} || {} },
    );
    delete $env{$_} for grep { !defined $env{$_} } keys %env;
    local %ENV = %env;
    unlink("$TMP/fake.log");
    my $here = getcwd();
    chdir($opt{cwd}) or die "$opt{cwd}: $!";
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, $^X, $HELPER, @{ $opt{args} });
    chdir($here) or die "$here: $!";
    close($in);
    my $stdout = do { local $/; <$out> } // '';
    my $stderr = do { local $/; <$err> } // '';
    waitpid($pid, 0);
    push @OUTPUTS, $stdout, $stderr;
    return { status => $? >> 8, stdout => $stdout, stderr => $stderr, log => slurp("$TMP/fake.log") // '' };
}

# ---------------------------------------------------------------------------
# The repository the scans run in.

my $REPO = "$TMP/shop";
my %SOURCE = (
    'src/config.js' => qq{// Settings for the upload service.\nconst region = "us-east-1";\nconst key = "$SECRET";\nmodule.exports = { region, key };\n},
    'src/server.js' => join('', map { "$_\n" } q|const express = require('express');|, q|const db = require('./db');|, '',
        q|const app = express();|, '', q|app.get('/user', (req, res) => {|, q|  const id = req.query.id;|, q|  // look the user up|,
        q|  db.query("SELECT * FROM users WHERE id = '" + id + "'", (err, rows) => res.json(rows));|, q|});|),
    'src/db.js'     => qq{const password = "$PASSWORD";\nmodule.exports = { password };\n},
    'src/repeat.js' => "function run(code) {\n  eval(code);\n  log(code);\n  eval(code);\n}\n",
    'api/run.py'    => "import os\nfrom flask import request\n\ndef ping():\n    os.system('ping ' + request.args['host'])\n",
    'db/schema.sql' => "CREATE TABLE users (id serial PRIMARY KEY, name text);\nGRANT ALL ON ALL TABLES IN SCHEMA public TO PUBLIC;\n",
    'db/seed.sql'   => "-- settings\nINSERT INTO settings VALUES ('api_key', '$SECRET2');\n",
    'notes.txt'     => "Deploy notes\nAPI_TOKEN $SECRET2\n",
    'Dockerfile'    => "FROM node:20\nCOPY . /app\nCMD [\"node\", \"src/server.js\"]\n",
    'k8s/deploy.yaml' => "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: shop\nspec: {}\n",
    'package-lock.json' => qq({"name": "shop", "lockfileVersion": 3, "packages": {}}\n),
    '.gitignore'    => ".env\nnode_modules/\n",
);
write_file("$REPO/$_", $SOURCE{$_}) for keys %SOURCE;
write_file("$REPO/.env", "API_TOKEN $SECRET\n");
write_file("$REPO/node_modules/lib/x.js", "eval(input);\n");
git($REPO, 'init', '-q');
git($REPO, 'add', '-A');
git($REPO, 'commit', '-q', '-m', 'first');

# Reports shaped like each scanner's, for the stand-ins to hand over. A
# shift moves the code findings in src/ down, as lines added above them do.
sub write_fixtures {
    my (%opt) = @_;
    my $shift = $opt{shift} // 0;
    my $secret_finding = sub {
        my (%f) = @_;
        return {
            RuleID => $f{rule}, Description => $f{description} // 'Identified a pattern that may indicate AWS credentials.',
            StartLine => $f{line}, EndLine => $f{line}, StartColumn => $f{column} // 1, EndColumn => ($f{column} // 1) + 19,
            Match => "key = \"$f{secret}\"", Secret => $f{secret}, Line => "const key = \"$f{secret}\";", File => $f{file},
            SymlinkFile => '', Commit => '', Entropy => 3.9, Tags => [], Fingerprint => "$f{file}:$f{rule}:$f{line}",
        };
    };
    # gitleaks counts a column one past the start on every line but the
    # first: the key on line 3 starts at column 14, and it says 15.
    write_json("$FIXTURES/gitleaks-default.json", [
        $secret_finding->(rule => 'aws-access-token', line => 3, column => 15, secret => $SECRET, file => 'src/config.js'),
        $secret_finding->(rule => 'aws-access-token', line => 1, column => 11, secret => $SECRET, file => '.env'),
        $secret_finding->(rule => 'generic-api-key', line => 2, column => 40, secret => $SECRET2, file => 'db/seed.sql'),
    ]);
    write_json("$FIXTURES/gitleaks-flashteams.json", [
        $secret_finding->(rule => 'flashteams-named-secret-without-operator', line => 2, column => 11, secret => $SECRET2,
            file => 'notes.txt', description => "A long random value written after a secret's name, with only spaces between them."),
    ]);
    my $result = sub {
        my ($id, $path, $line, %f) = @_;
        return {
            check_id => $id, path => $path,
            start => { line => $line, col => $f{col} // 3, offset => 0 }, end => { line => $f{end_line} // $line, col => $f{end_col} // 40, offset => 0 },
            extra => {
                message  => $f{message} // 'This code matches a rule. Fix it.',
                severity => $f{severity} // 'ERROR',
                metadata => $f{metadata} // {},
                lines    => 'THE-FLAGGED-CODE-AS-OPENGREP-QUOTES-IT',
                metavars => { '$X' => { abstract_content => 'THE-FLAGGED-CODE-AS-OPENGREP-QUOTES-IT' } },
            },
        };
    };
    my $sql_injection = $result->('ft.security.js.sql-injection', 'src/server.js', 9 + $shift,
        message => 'Request data is put into the text of a SQL query, so a crafted value can change the query. Pass the value as a bound parameter.',
        metadata => { category => 'security', impact => 'high', cwe => 'CWE-89' });
    my $concat = $result->('ft.hotspot.js.sql-concat-query', 'src/server.js', 9 + $shift, col => 3, end_col => 50,
        message => 'This SQL statement is built by concatenating values and then run.', severity => 'WARNING',
        metadata => { category => 'hotspot', impact => 'medium', cwe => ['CWE-89: SQL Injection'] });
    write_json("$FIXTURES/opengrep-security.json", {
        version => '1.30.0', errors => [ { message => 'one file did not parse' } ], paths => { scanned => [] },
        results => [
            $sql_injection,
            $concat, $concat,
            $result->('ft.security.py.command-injection', 'api/run.py', 5, message => 'Request data reaches a shell command. Use a list of arguments.',
                metadata => { category => 'security', impact => 'blocker', cwe => 'CWE-78' }),
            $result->('ft.hotspot.js.eval-dynamic-code', 'src/repeat.js', 2 + $shift, message => 'Code is run from a value. Avoid eval.',
                severity => 'WARNING', metadata => { category => 'hotspot', impact => 'medium', cwe => 'CWE-95' }),
            $result->('ft.hotspot.js.eval-dynamic-code', 'src/repeat.js', 4 + $shift, message => 'Code is run from a value. Avoid eval.',
                severity => 'WARNING', metadata => { category => 'hotspot', impact => 'medium', cwe => 'CWE-95' }),
            $result->('ft.hotspot.js.hardcoded-secret', 'src/db.js', 1, col => 7, end_col => 35,
                message => 'A secret is written into the code. Load it from the environment.',
                metadata => { category => 'hotspot', impact => 'high', cwe => 'CWE-798' }),
            $result->('custom.rule-without-metadata', 'src/server.js', 7 + $shift, message => 'no sentence end here', severity => 'WARNING'),
            $result->('ft.hotspot.js.eval-dynamic-code', 'node_modules/lib/x.js', 1, metadata => { category => 'hotspot', impact => 'medium' }),
        ],
    });
    write_json("$FIXTURES/opengrep-sql.json", {
        errors => [],
        results => [
            $result->('ft.sql.grant-all-to-public', 'db/schema.sql', 2, col => 1, message => 'Every privilege is granted to PUBLIC. Grant only what each role needs.',
                metadata => { category => 'security', impact => 'high', cwe => 'CWE-732' }),
            $result->('ft.db.public-grant', 'db/schema.sql', 2, col => 1, message => 'A grant to everyone. Narrow it.',
                metadata => { category => 'security', impact => 'medium' }),
            $sql_injection,
            $result->('ft.security.js.nosql-injection', 'src/server.js', 7 + $shift, message => 'Request data reaches a NoSQL query. Check its type.',
                metadata => { category => 'security', impact => 'high', cwe => 'CWE-943' }),
            $result->('ft.security.py.command-injection', 'api/run.py', 5, message => 'Request data reaches a shell command. Use a list.',
                metadata => { category => 'security', impact => 'blocker', cwe => 'CWE-78' }),
        ],
    });
    write_json("$FIXTURES/trivy-config.json", {
        SchemaVersion => 2,
        Results => [
            {
                Target => 'Dockerfile', Class => 'config', Type => 'dockerfile',
                Misconfigurations => [
                    {
                        ID => 'DS-0002', Title => "Image user should not be 'root'",
                        Message => 'Specify at least 1 USER command in Dockerfile with non-root user as argument',
                        Description => 'Running containers with the root user can lead to a container escape.',
                        Resolution => "Add 'USER <non root user name>' line to the Dockerfile", Severity => 'HIGH', Status => 'FAIL',
                        PrimaryURL => 'https://avd.aquasec.com/misconfig/ds-0002',
                        CauseMetadata => { Code => { Lines => [ { Content => 'THE-FLAGGED-CODE-AS-TRIVY-QUOTES-IT' } ] } },
                    },
                    { ID => 'DS-0001', Title => 'A check that passed', Severity => 'MEDIUM', Status => 'PASS' },
                ],
            },
            {
                Target => 'k8s/deploy.yaml', Class => 'config', Type => 'kubernetes',
                Misconfigurations => [
                    { ID => 'KSV-0001', Title => 'Something Trivy cannot rate', Message => 'Check it.', Severity => 'UNKNOWN',
                      Status => 'FAIL', CauseMetadata => { StartLine => 4, EndLine => 4 } },
                ],
            },
        ],
    });
    write_json("$FIXTURES/trivy-vuln.json", {
        Results => [
            {
                Target => 'package-lock.json', Class => 'lang-pkgs', Type => 'npm',
                Vulnerabilities => [
                    { VulnerabilityID => 'CVE-2020-8203', PkgName => 'lodash', InstalledVersion => '4.17.15', FixedVersion => '4.17.19',
                      Severity => 'HIGH', Title => 'nodejs-lodash: prototype pollution in zipObjectDeep function',
                      Description => 'Prototype pollution attack when using _.zipObjectDeep in lodash before 4.17.20.',
                      PrimaryURL => 'https://avd.aquasec.com/nvd/cve-2020-8203', CweIDs => ['CWE-770'] },
                    { VulnerabilityID => 'GHSA-aaaa-bbbb-cccc', PkgName => 'minimist', InstalledVersion => '1.2.0', Severity => 'LOW',
                      Title => 'minimist: an older issue' },
                ],
            },
        ],
    });
    return;
}
write_fixtures();

sub find_rule {
    my ($findings, $rule, $path) = @_;
    return grep { $_->{rule} eq $rule && (!defined $path || ($_->{path} // '') eq $path) } @$findings;
}

my %FINDING_KEYS = map { $_ => 1 } qw(fingerprint category tool rule severity path line title detail recommendation cwe);
my %SEVERITY_RANK = (critical => 0, high => 1, medium => 2, low => 3, info => 4);

sub check_shape {
    my ($findings, $what) = @_;
    my @bad;
    for my $f (@$findings) {
        push @bad, 'keys ' . join(',', sort keys %$f) if join(',', sort keys %$f) ne join(',', sort keys %FINDING_KEYS);
        push @bad, "fingerprint $f->{fingerprint}" unless ($f->{fingerprint} // '') =~ /\A[0-9a-f]{32}\z/;
        push @bad, "category $f->{category}" unless ($f->{category} // '') =~ /\A(?:secret|security|hotspot|sql|iac|dependency|architecture)\z/;
        push @bad, "severity $f->{severity}" unless defined $SEVERITY_RANK{ $f->{severity} // '' };
        push @bad, "tool $f->{tool}" unless ($f->{tool} // '') =~ /\A(?:gitleaks|opengrep|semgrep|trivy|agent)\z/;
        push @bad, "line $f->{line}" if defined $f->{line} && $f->{line} !~ /\A[1-9][0-9]*\z/;
        push @bad, 'title too long' if length($f->{title} // '') > 300 || ($f->{title} // '') eq '';
        push @bad, "cwe $f->{cwe}" if defined $f->{cwe} && $f->{cwe} !~ /\ACWE-[0-9]+\z/;
        push @bad, "path $f->{path}" if defined $f->{path} && ($f->{path} =~ m{\A/} || $f->{path} =~ m{(?:\A|/)\.\.(?:/|\z)});
    }
    is("@bad", '', "$what: every finding has the normalized shape");
    my @ranks = map { $SEVERITY_RANK{ $_->{severity} } } @$findings;
    is_deeply(\@ranks, [ sort { $a <=> $b } @ranks ], "$what: the most severe come first");
    my %seen;
    is(scalar(grep { $seen{ $_->{fingerprint} }++ } @$findings), 0, "$what: no two findings share a fingerprint");
    return;
}

# ---------------------------------------------------------------------------
# Pure functions, loaded as a library.

{
    is_deeply([ Scan::split_message('Request data is put into a query. Pass it as a parameter.') ],
        [ 'Request data is put into a query.', 'Pass it as a parameter.' ], 'a rule message: first sentence, then the rest');
    is_deeply([ Scan::split_message('Use req.query.id carefully. Then check it.') ],
        [ 'Use req.query.id carefully.', 'Then check it.' ], 'a dot inside code does not end the sentence');
    is_deeply([ Scan::split_message('one long phrase without an end') ], [ 'one long phrase without an end', '' ],
        'a message of one phrase is all title');
    my ($long) = Scan::split_message('x' x 400);
    is(length($long), 300, 'a title is cut to 300 characters');
    is(Scan::cwe_of('CWE-89'), 'CWE-89', 'a CWE as given');
    is(Scan::cwe_of(['CWE-79: Cross-site Scripting']), 'CWE-79', 'a CWE from a list with its name');
    is(Scan::cwe_of('none'), undef, 'no CWE');

    my %remote = (
        'https://user:s3cret@github.com/org/repo.git'    => 'https://github.com/org/repo.git',
        'https://x-access-token:ghp_abc@host.example/a/b' => 'https://host.example/a/b',
        'https://host.example/a/b?private_token=abc#x'    => 'https://host.example/a/b',
        'ssh://git@github.com:22/org/repo.git'            => 'ssh://github.com:22/org/repo.git',
        'git@github.com:org/repo.git'                     => 'github.com:org/repo.git',
        'user:pass@host.example:org/repo.git'             => 'host.example:org/repo.git',
        'github.com:org/repo.git'                         => 'github.com:org/repo.git',
        'HTTPS://Host.example/x'                          => 'https://Host.example/x',
        '/Users/me/repos/shop.git'                        => undef,
        '../shop.git'                                     => undef,
        'file:///Users/me/shop.git'                       => undef,
        'C:/Users/me/shop.git'                            => undef,
        'shop'                                            => undef,
        ''                                                => undef,
    );
    is(Scan::clean_remote_url($_), $remote{$_}, "remote address '$_'") for sort keys %remote;

    ok(Scan::bundle_path_ok('opengrep/security/python.yaml'), 'a bundle path inside the folder');
    ok(!Scan::bundle_path_ok($_), "a bundle path refused: '$_'")
      for '../x.yaml', 'a/../b.yaml', 'a/..b.yaml', '/etc/passwd', 'C:/x.yaml', 'a\\b.yaml', 'a//b.yaml', '.hidden', '', "a\nb",
      '.flashteams-rules.json';

    my ($cut, $was) = Scan::cut_chars('a' x 5000, 4000);
    ok($was && length($cut) == 4000, 'a summary is cut to 4,000 characters');
    my $report = "\x{e9}" x 60000;    # two bytes each in UTF-8
    my ($short, $cut_report) = Scan::cut_bytes($report, 100000);
    my $bytes = Encode::encode('UTF-8', $short);
    ok($cut_report && length($bytes) <= 100000, 'a report is cut to 100,000 bytes');
    ok(eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK()); 1 }, 'and at the end of a character');
    like($short, qr/cut to fit/, 'and says it was cut');
    is_deeply([ Scan::cut_bytes('short', 100000) ], [ 'short', 0 ], 'a short report is left as it is');

    # Fingerprints: the same finding keeps its fingerprint when the line
    # moves, and repeats of one line differ.
    my $text = sub { my ($path, $line) = @_; return { 2 => 'eval(code);', 4 => 'eval(code);', 12 => 'eval(code);', 14 => "\t eval(code);  " }->{$line} };
    my @before = map { { category => 'hotspot', rule => 'r', path => 'a.js', line => $_ } } 2, 4;
    my @after = map { { category => 'hotspot', rule => 'r', path => 'a.js', line => $_ } } 12, 14;
    Scan::add_fingerprints(\@before, $text);
    Scan::add_fingerprints(\@after, $text);
    isnt($before[0]{fingerprint}, $before[1]{fingerprint}, 'two findings on the same line text get different fingerprints');
    is_deeply([ map { $_->{fingerprint} } @after ], [ map { $_->{fingerprint} } @before ],
        'the fingerprints stay when the lines move, and whitespace does not count');
    my @secret = ({ category => 'secret', rule => 'r', path => 'a.js', line => 2, _text => '' });
    Scan::add_fingerprints(\@secret, sub { die 'a secret line is never read' });
    is($secret[0]{fingerprint}, substr(sha256_hex("secret\nr\na.js\n\n0"), 0, 32), 'a secret has no line text in its fingerprint');
}

# ---------------------------------------------------------------------------
# doctor

{
    my $some = fakes('some', qw(gitleaks trivy brew));
    my $r = helper(cwd => $REPO, fakes => $some, args => ['doctor'], env => { FLASHTEAMS_SCAN_PLATFORM => 'darwin-arm64' });
    is($r->{status}, 0, 'doctor exits 0');
    like($r->{stdout}, qr/^  gitleaks  8\.30\.1 +ready \(PATH: \Q$some\E\/gitleaks\)$/m, 'doctor finds gitleaks on the PATH, with its version');
    like($r->{stdout}, qr/^  trivy     0\.74\.0 +ready/m, "doctor reads Trivy's version");
    like($r->{stdout}, qr/^  opengrep  missing$/m, 'doctor says opengrep is missing');
    like($r->{stdout}, qr/^  git       \S+ +ready/m, 'doctor checks git');
    like($r->{stdout}, qr/^  opengrep: perl "\Q$HELPER\E" install opengrep$/m, 'doctor gives the exact install command');
    like($r->{stdout}, qr/^Missing: opengrep$/m, 'only opengrep is missing');
    unlike($r->{stdout}, qr/brew install opengrep/, 'opengrep is not offered from Homebrew');

    my $none = fakes('none', 'brew');
    $r = helper(cwd => $REPO, fakes => $none, args => ['doctor'], env => { FLASHTEAMS_SCAN_PLATFORM => 'darwin-arm64' });
    like($r->{stdout}, qr/^  gitleaks: perl "\Q$HELPER\E" install gitleaks   or   brew install gitleaks$/m,
        'on a Mac with Homebrew, both ways to install gitleaks');
    like($r->{stdout}, qr/^All at once: perl "\Q$HELPER\E" install gitleaks opengrep trivy$/m, 'and all at once');
    like($r->{stdout}, qr/^With Homebrew: brew install gitleaks trivy$/m, 'and with Homebrew');
    $r = helper(cwd => $REPO, fakes => $none, args => ['doctor'], env => { FLASHTEAMS_SCAN_PLATFORM => 'linux-x64' });
    unlike($r->{stdout}, qr/brew/, 'no Homebrew on Linux');

    $r = helper(cwd => $REPO, fakes => $none, args => [ 'doctor', '--json' ], env => { FLASHTEAMS_SCAN_PLATFORM => 'linux-x64' });
    my $report = eval { $JSON->decode($r->{stdout}) };
    ok($report, 'doctor --json prints JSON');
    is_deeply($report->{missing}, [qw(gitleaks opengrep trivy)], 'doctor --json lists the missing scanners');
    is($report->{install_all}, qq{perl "$HELPER" install gitleaks opengrep trivy}, 'doctor --json gives the install command');
    is($report->{platform}, 'linux-x64', 'doctor --json names the platform');

    # The tools folder comes before the PATH.
    my $folder = "$TMP/tools-folder";
    write_file("$folder/gitleaks", $FAKE{gitleaks}, 0755);
    my $old = fakes('old', 'gitleaks');
    write_file("$old/gitleaks", "#!/bin/sh\necho 8.0.0\n", 0755);
    $r = helper(cwd => $REPO, fakes => $old, args => ['doctor'], env => { FLASHTEAMS_TOOLS_DIR => $folder });
    like($r->{stdout}, qr/^  gitleaks  8\.30\.1 +ready \(tools folder\)$/m, 'the tools folder comes before the PATH');

    my $semgrep = fakes('semgrep-only', qw(gitleaks semgrep trivy));
    $r = helper(cwd => $REPO, fakes => $semgrep, args => ['doctor']);
    like($r->{stdout}, qr/semgrep will run FlashTeams' code rules in place of opengrep/, 'semgrep stands in for opengrep');

    $r = helper(cwd => $REPO, fakes => $none, args => ['doctor'], env => { FLASHTEAMS_SCAN_PLATFORM => 'windows-x64' });
    is($r->{status}, 0, 'doctor exits 0 on Windows');
    like($r->{stdout}, qr/install does not work on Windows/, 'doctor says install does not work on Windows');
    like($r->{stdout}, qr{https://github\.com/gitleaks/gitleaks/releases/tag/v8\.30\.1}, 'and points to the release pages');
}

# ---------------------------------------------------------------------------
# install

{
    my $curl = fakes('curl', 'curl');
    my $tools = "$TMP/installed";
    my $r = helper(cwd => $REPO, fakes => $curl, args => [ 'install', 'gitleaks' ],
        env => { FLASHTEAMS_TOOLS_DIR => $tools, FLASHTEAMS_SCAN_PLATFORM => 'linux-x64' });
    is($r->{status}, 1, 'install fails when the download does not match');
    like($r->{stdout}, qr/does not match its pinned checksum, so nothing was installed/, 'and says so');
    like($r->{log}, qr{curl -fsSL --proto =https --proto-redir =https .*https://github\.com/gitleaks/gitleaks/releases/download/v8\.30\.1/gitleaks_8\.30\.1_linux_x64\.tar\.gz},
        'it downloads the pinned release over https only');
    ok(!-e "$tools/gitleaks", 'nothing is installed');
    opendir(my $dh, $tools);
    is(scalar(grep { !/\A\.\.?\z/ } readdir($dh)), 0, 'and the download is gone');

    $r = helper(cwd => $REPO, fakes => $curl, args => [ 'install', 'trivy' ],
        env => { FLASHTEAMS_TOOLS_DIR => $tools, FLASHTEAMS_SCAN_PLATFORM => 'windows-x64' });
    is($r->{status}, 1, 'install does not work on Windows');
    like($r->{stdout}, qr{trivy 0\.74\.0: https://github\.com/aquasecurity/trivy/releases/tag/v0\.74\.0}, 'it points to the release page');
    is($r->{log}, '', 'and downloads nothing');

    $r = helper(cwd => $REPO, fakes => $curl, args => [ 'install', 'nmap' ]);
    is($r->{status}, 2, 'install refuses a tool it does not know');
    $r = helper(cwd => $REPO, fakes => $curl, args => [ 'install', 'semgrep' ]);
    like($r->{stderr}, qr/install opengrep/, 'install points from semgrep to opengrep');

    # The pins: each scanner, each platform, a full checksum.
    my $source = slurp($HELPER);
    for my $tool (qw(gitleaks opengrep trivy)) {
        my ($block) = $source =~ /^    $tool => \{\n(.*?)\n    \},\n/ms;
        for my $platform (qw(darwin-arm64 darwin-x64 linux-x64 linux-arm64)) {
            like($block // '', qr/'$platform' +=> \[ '[^']+', +'[0-9a-f]{64}' \]/, "$tool is pinned for $platform");
        }
    }
    like($source, qr/version => '8\.30\.1'/, 'gitleaks 8.30.1');
    like($source, qr/version => '1\.30\.0'/, 'opengrep 1.30.0');
    like($source, qr/version => '0\.74\.0'/, 'trivy 0.74.0');
}

# ---------------------------------------------------------------------------
# rules

my $SQL_RULES = <<'EOF';
rules:
  - id: ft.sql.grant-all-to-public
    languages: [generic]
    message: Every privilege is granted to PUBLIC.
    severity: ERROR
    pattern-regex: (?i)grant\s+all
  - id: ft.db.public-grant
    languages: [generic]
    message: A grant to everyone.
    severity: WARNING
    pattern-regex: (?i)to\s+public
EOF
my %BUNDLE_FILES = (
    'opengrep/security/javascript.yaml' => "rules: []\n",
    'opengrep/hotspot/javascript.yaml'  => "rules: []\n",
    'opengrep/sql/sql.yaml'             => $SQL_RULES,
    'gitleaks/flashteams.toml'          => "title = \"FlashTeams secret rules\"\n",
);
sub bundle {
    my (%opt) = @_;
    my $bytes = $JSON->encode({ format => $opt{format} // 1, version => $opt{version} // 'abc123def456',
        tools => { gitleaks => '8.30.1', opengrep => '1.30.0', trivy => '0.74.0' }, files => $opt{files} // \%BUNDLE_FILES });
    my $file = "$TMP/bundles/" . ($opt{name} // 'bundle') . '.json';
    write_file($file, $bytes);
    return ("file://$file", sha256_hex($bytes), $file);
}

my $RULES;
{
    my $cache = "$TMP/rules-cache";
    my ($url, $sum, $file) = bundle();
    my $r = helper(cwd => $REPO, args => [ 'rules', '--url', $url, '--sha256', $sum ]);
    is($r->{status}, 0, 'rules downloads and unpacks a bundle');
    is($r->{stdout}, "$cache/abc123def456\n", 'rules prints only the folder, named for the version');
    $RULES = "$cache/abc123def456";
    is(slurp("$RULES/$_"), $BUNDLE_FILES{$_}, "rules wrote $_") for sort keys %BUNDLE_FILES;
    my $mark = json_file("$RULES/.flashteams-rules.json");
    is($mark->{sha256}, $sum, 'rules notes the checksum of the copy');

    unlink($file);
    $r = helper(cwd => $REPO, args => [ 'rules', '--url', $url, '--sha256', $sum ]);
    is($r->{status}, 0, 'rules reuses a complete copy of the same bundle');
    is($r->{stdout}, "$RULES\n", 'without downloading it again');

    my $other = "$TMP/other-cache";
    ($url, $sum) = bundle(name => 'changed');
    $r = helper(cwd => $REPO, args => [ 'rules', '--url', $url, '--sha256', 'f' x 64, '--dir', $other ]);
    is($r->{status}, 1, 'rules refuses a bundle that does not match its checksum');
    like($r->{stderr}, qr/does not match its checksum/, 'and says so');
    opendir(my $dh, $other);
    is(scalar(grep { !/\A\.\.?\z/ } readdir($dh)), 0, 'and writes nothing');

    for my $bad ('../escape.yaml', '/tmp/escape.yaml', 'opengrep/../../escape.yaml') {
        my ($bad_url, $bad_sum) = bundle(name => 'bad', files => { %BUNDLE_FILES, $bad => "x\n" });
        $r = helper(cwd => $REPO, args => [ 'rules', '--url', $bad_url, '--sha256', $bad_sum, '--dir', $other ]);
        is($r->{status}, 1, "rules refuses a bundle with the path $bad");
        like($r->{stderr}, qr/outside its folder/, 'and says why');
    }
    ok(!-e "$TMP/escape.yaml" && !-e '/tmp/escape.yaml', 'no file was written outside the folder');
    opendir($dh, $other);
    is(scalar(grep { !/\A\.\.?\z/ } readdir($dh)), 0, 'nor inside it');

    my ($v2, $v2_sum) = bundle(name => 'v2', format => 2);
    $r = helper(cwd => $REPO, args => [ 'rules', '--url', $v2, '--sha256', $v2_sum, '--dir', $other ]);
    is($r->{status}, 1, 'rules refuses a format it does not read');

    # Without --url, rules asks FlashTeams through the flashteams command.
    my ($asked, $asked_sum) = bundle(name => 'asked', version => 'fedcba987654');
    write_file("$TMP/ft-rules-answer", $JSON->encode({ success => JSON::PP::true, url => $asked, sha256 => $asked_sum,
        version => 'fedcba987654', expires_at => '2026-10-22T10:10:00Z' }));
    $r = helper(cwd => $REPO, args => ['rules']);
    is($r->{status}, 0, 'rules asks FlashTeams for the rules');
    is($r->{stdout}, "$cache/fedcba987654\n", 'and unpacks what it answered');
    is(slurp("$TMP/ft-args"), "get_scan_rules\0", 'through flashteams get_scan_rules, which prints the tool\'s own answer');

    # The same answer wrapped the way --output json wraps it still reads.
    write_file("$TMP/ft-rules-answer", $JSON->encode({ text => $JSON->encode({ success => JSON::PP::true, url => $asked, sha256 => $asked_sum,
        version => 'fedcba987654' }) }));
    $r = helper(cwd => $REPO, args => [ 'rules', '--dir', "$TMP/wrapped-cache" ]);
    is($r->{status}, 0, 'rules reads an answer wrapped in text');
    is($r->{stdout}, "$TMP/wrapped-cache/fedcba987654\n", 'and unpacks it');

    write_file("$TMP/ft-rules-answer", $JSON->encode({ success => JSON::PP::false, reason => 'not_allowed' }));
    $r = helper(cwd => $REPO, args => [ 'rules', '--dir', $other ], env => { FAKE_FT_EXIT => 1 });
    is($r->{status}, 1, 'rules passes on a refusal');
    like($r->{stderr}, qr/not_allowed/, 'with its reason');

    $r = helper(cwd => $REPO, fakes => fakes('none'), args => [ 'rules', '--dir', $other ]);
    is($r->{status}, 3, 'rules exits 3 without the flashteams command');
    $r = helper(cwd => $REPO, args => [ 'rules', '--url', $url ]);
    is($r->{status}, 2, 'rules wants both --url and --sha256, or neither');
}

# ---------------------------------------------------------------------------
# run: security, quick

my $OUT = "$TMP/work";
my @WORK;    # every work folder, checked at the end
sub work { my ($name) = @_; push @WORK, "$OUT/$name"; return "$OUT/$name" }

my %QUICK;
{
    my $out = work('quick');
    my $r = helper(cwd => "$REPO/src", args => [ 'run', '--kind', 'security', '--mode', 'quick', '--rules', $RULES, '--out', $out ]);
    is($r->{status}, 0, 'a quick security scan runs from a folder inside the repository') or diag($r->{stderr});
    my $findings = json_file("$out/findings.json");
    %QUICK = (findings => $findings, out => $out, stdout => $r->{stdout});
    check_shape($findings, 'security quick');

    my ($key) = find_rule($findings, 'gitleaks:aws-access-token');
    ok($key, 'the committed key is found');
    is_deeply([ @$key{qw(category severity path line tool cwe)} ], [qw(secret critical src/config.js 3 gitleaks CWE-798)],
        "gitleaks' own rules: a secret, critical");
    is(scalar(find_rule($findings, 'gitleaks:aws-access-token')), 1, 'the key in .env, which git ignores, is left out');
    my ($named) = find_rule($findings, 'gitleaks:flashteams-named-secret-without-operator');
    is($named && $named->{severity}, 'medium', "FlashTeams' own secret rules: medium");
    is($named && $named->{title}, "A long random value written after a secret's name, with only spaces between them.",
        "FlashTeams' secret rules keep their description as the title");

    my ($sql) = find_rule($findings, 'ft.security.js.sql-injection');
    is_deeply([ @$sql{qw(category severity path line cwe tool)} ], [qw(security high src/server.js 9 CWE-89 opengrep)],
        'a code rule: its category, impact and CWE');
    is($sql->{title}, 'Request data is put into the text of a SQL query, so a crafted value can change the query.', 'title: the first sentence');
    is($sql->{detail}, 'Pass the value as a bound parameter.', 'detail: the rest');
    is(scalar(find_rule($findings, 'ft.hotspot.js.sql-concat-query')), 1, 'a rule matching the same code twice is one finding');
    my ($concat) = find_rule($findings, 'ft.hotspot.js.sql-concat-query');
    is_deeply([ @$concat{qw(category severity cwe)} ], [qw(hotspot medium CWE-89)], 'a hotspot, with its CWE from a list');
    my ($blocker) = find_rule($findings, 'ft.security.py.command-injection');
    is($blocker->{severity}, 'critical', 'impact blocker is critical');
    my ($plain) = find_rule($findings, 'custom.rule-without-metadata');
    is_deeply([ @$plain{qw(category severity title detail)} ], [ 'hotspot', 'medium', 'no sentence end here', '' ],
        'a rule without metadata: a hotspot, its severity from WARNING');
    is(scalar(find_rule($findings, 'ft.hotspot.js.eval-dynamic-code', 'node_modules/lib/x.js')), 0,
        'a finding in a folder git ignores is left out');
    is(scalar(grep { $_->{category} =~ /\A(?:iac|dependency)\z/ } @$findings), 0, 'quick mode checks no infrastructure or dependencies');

    my $tools = json_file("$out/tools.json");
    is_deeply([ map { "$_->{name} $_->{status}" } @$tools ], [ 'gitleaks ran', 'opengrep ran', 'trivy-config skipped', 'trivy-vuln skipped' ],
        'each tool and what it did');
    like($tools->[0]{note}, qr/FlashTeams' secret rules/, "gitleaks ran FlashTeams' rules too");
    like($tools->[0]{note}, qr/left out 1 in files git ignores/, 'and says what it left out');
    like($tools->[1]{note}, qr/1 file it could not read fully/, "opengrep's errors are counted");
    like($tools->[2]{note}, qr/full mode only/, 'Trivy runs only in full mode');
    is_deeply([ map { $_->{version} } @$tools ], [qw(8.30.1 1.30.0 0.74.0 0.74.0)], 'each tool has its version');

    my $scan = json_file("$out/scan.json");
    is_deeply([ @$scan{qw(kind mode path rules_version root)} ], [ 'security', 'quick', '', 'abc123def456', $REPO ],
        'scan.json says what was scanned');

    my @gitleaks = $r->{log} =~ /^gitleaks (.*)$/mg;
    is(scalar(@gitleaks), 2, 'gitleaks runs twice');
    like($gitleaks[0], qr/\Adir \. --report-format json --report-path \S+ --no-banner --exit-code 0 --max-target-megabytes 5 --log-level error --redact\z/,
        'first with its own rules, redacting secrets');
    like($gitleaks[1], qr/--redact --config \Q$RULES\E\/gitleaks\/flashteams\.toml\z/, "then with FlashTeams' rules");
    my ($opengrep) = $r->{log} =~ /^opengrep (.*)$/m;
    like($opengrep, qr/\Ascan --config \Q$RULES\E\/opengrep\/security --config \Q$RULES\E\/opengrep\/hotspot --json-output=\S+ --disable-version-check --no-git-ignore --no-rewrite-rule-ids --taint-intrafile --timeout 5 --timeout-threshold 3 --max-target-bytes 1000000 --quiet /,
        "opengrep runs FlashTeams' security and hotspot rules as the cloud scanner does");
    like($opengrep, qr/--exclude=node_modules .*--exclude=vendor .*--exclude=dist .*--exclude=build .*--exclude=\.venv .*--exclude=\*\.min\.js \.\z/,
        'leaving out dependencies and built output');
    unlike($r->{log}, qr/^trivy/m, 'Trivy does not run in quick mode');

    like($r->{stdout}, qr/^FlashTeams security scan \(quick mode\) of the whole repository$/m, 'the summary says what was scanned');
    like($r->{stdout}, qr/^Findings: \d+ \(critical \d+, high \d+, medium \d+, low \d+, info \d+\)$/m, 'the counts by severity');
    my @lines = $r->{stdout} =~ /^(#\d+ .*)$/mg;
    is(scalar(@lines), scalar(@$findings), 'every finding is listed when there are fewer than 40');
    like($lines[0], qr/\A#1 critical \S+ \S+:\d+ .+ \(\S+\)\z/, 'as #n severity category path:line title (rule)');
    my ($n) = grep { $findings->[$_]{rule} eq 'ft.security.js.sql-injection' } 0 .. $#$findings;
    like($r->{stdout}, qr/^#@{[ $n + 1 ]} high security src\/server\.js:9 Request data is put into the text of a SQL query/m,
        'numbered as in findings.json');
    unlike($r->{stdout}, qr/CODE-ON-STDOUT/, "opengrep's own output is not passed on");
    ok(!-e "$out/payload.json", 'a scan leaves no payload behind');
    opendir(my $dh, $out);
    is_deeply([ sort grep { !/\A\.\.?\z/ } readdir($dh) ], [qw(findings.json hidden.json scan.json tools.json)],
        "the work folder keeps only the helper's own files; the scanners' reports are gone");

    my $hidden = json_file("$out/hidden.json");
    my ($credential) = grep { $findings->[$_]{rule} eq 'ft.hotspot.js.hardcoded-secret' } 0 .. $#$findings;
    ok($hidden->{ $credential + 1 }, 'a hard-coded password rule is hidden like a secret');
    my ($key_id) = grep { $findings->[$_]{rule} eq 'gitleaks:aws-access-token' } 0 .. $#$findings;
    ok($hidden->{ $key_id + 1 }, 'so is the key');
}

# ---------------------------------------------------------------------------
# show

{
    my $out = $QUICK{out};
    my $findings = $QUICK{findings};
    my ($key) = grep { $findings->[$_]{rule} eq 'gitleaks:aws-access-token' } 0 .. $#$findings;
    my ($sql) = grep { $findings->[$_]{rule} eq 'ft.security.js.sql-injection' } 0 .. $#$findings;
    my $r = helper(cwd => $REPO, args => [ 'show', '--out', $out, '--ids', join(',', $key + 1, $sql + 1, 999) ]);
    is($r->{status}, 0, 'show prints findings');
    like($r->{stdout}, qr/^#@{[ $key + 1 ]} critical secret src\/config\.js:3$/m, 'show heads each finding');
    like($r->{stdout}, qr/^  >     3 \| const key = "\[hidden\]$/m, "show hides the key from where it starts, though gitleaks' column is one past it");
    like($r->{stdout}, qr/^        2 \| const region = "us-east-1";$/m, 'and shows the lines around it');
    like($r->{stdout}, qr/^  >     9 \|   db\.query\("SELECT \* FROM users WHERE id = '" \+ id \+ "'"/m, 'show marks the flagged line');
    like($r->{stdout}, qr/^  Detail: Pass the value as a bound parameter\.$/m, 'show prints the detail');
    like($r->{stdout}, qr/^  Fingerprint: [0-9a-f]{32}$/m, 'and the fingerprint');
    like($r->{stdout}, qr/^#999: there is no such finding/m, 'show says when a number is wrong');

    $r = helper(cwd => $REPO, args => [ 'show', '--out', $out, '--ids', $key + 1, '--context', 0 ]);
    like($r->{stdout}, qr/Code:\n  >     3 \| const key = "\[hidden\]\n\n\z/, '--context 0 shows only the line');

    my $work = { hidden => { 1 => { path => 'a.txt', line => 1, end_line => 2 } } };
    is_deeply(Scan::hidden_lines($work, 'a.txt', [ 'line one', 'line two', 'line three' ]),
        { 1 => '[hidden]', 2 => '[hidden]' }, 'a secret over several lines hides each of them');
    $work = { hidden => { 1 => { path => 'a.txt', line => 1, start_column => 5 }, 2 => { path => 'a.txt', line => 1, start_column => 12 } } };
    is_deeply(Scan::hidden_lines($work, 'a.txt', ['key=abc other=def']), { 1 => '[hidden]' }, 'two secrets on one line hide all of it');
    $work = { hidden => { 1 => { path => 'a.txt', line => 1, start_column => 9 } } };
    is_deeply(Scan::hidden_lines($work, 'a.txt', ['token = exampleexample']), { 1 => 'token =[hidden, has placeholder words]' },
        'show says when the hidden text has placeholder words');
    $work = { hidden => { 1 => { path => 'a.txt', line => 1, start_column => 12 } } };
    is_deeply(Scan::hidden_lines($work, 'a.txt', ['key = "AKIAQWERTYZXCV"']), { 1 => 'key = "[hidden]' },
        'a start inside a word moves back to the start of the word');
}

# ---------------------------------------------------------------------------
# run: security, full

{
    my $out = work('full');
    my $cache = "$TMP/trivy-cache";
    my $r = helper(cwd => $REPO, args => [ 'run', '--kind', 'security', '--mode', 'full', '--rules', $RULES, '--out', $out ],
        env => { FLASHTEAMS_TRIVY_CACHE => $cache });
    is($r->{status}, 0, 'a full security scan runs') or diag($r->{stderr});
    my $findings = json_file("$out/findings.json");
    check_shape($findings, 'security full');
    my ($root) = find_rule($findings, 'trivy:DS-0002');
    is_deeply([ @$root{qw(category severity path line tool)} ], [ 'iac', 'high', 'Dockerfile', undef, 'trivy' ], 'an infrastructure check');
    is($root->{title}, "Image user should not be 'root'", "its title is Trivy's");
    is($root->{detail}, 'Specify at least 1 USER command in Dockerfile with non-root user as argument. Running containers with the root user can lead to a container escape. More: https://avd.aquasec.com/misconfig/ds-0002.',
        'its detail is the message and description, as sentences');
    is($root->{recommendation}, "Add 'USER <non root user name>' line to the Dockerfile", 'its recommendation is the resolution');
    my ($unknown) = find_rule($findings, 'trivy:KSV-0001');
    is_deeply([ @$unknown{qw(severity path line)} ], [qw(info k8s/deploy.yaml 4)], 'UNKNOWN is info, with its line');
    is(scalar(find_rule($findings, 'trivy:DS-0001')), 0, 'a check that passed is not a finding');
    my ($lodash) = find_rule($findings, 'trivy:CVE-2020-8203');
    is_deeply([ @$lodash{qw(category severity path line title recommendation cwe)} ],
        [ 'dependency', 'high', 'package-lock.json', undef, 'lodash 4.17.15: CVE-2020-8203', 'Upgrade to 4.17.19', 'CWE-770' ],
        'a vulnerable dependency');
    my ($nofix) = find_rule($findings, 'trivy:GHSA-aaaa-bbbb-cccc');
    is_deeply([ @$nofix{qw(severity recommendation)} ], [ 'low', '' ], 'with no fixed version, no recommendation');
    my $tools = json_file("$out/tools.json");
    is_deeply([ map { "$_->{name} $_->{status}" } @$tools ], [ 'gitleaks ran', 'opengrep ran', 'trivy-config ran', 'trivy-vuln ran' ],
        'in full mode every tool runs');
    my ($config) = $r->{log} =~ /^trivy (config .*)$/m;
    like($config, qr/\Aconfig --skip-check-update --disable-telemetry --skip-version-check --cache-dir \S+ --format json --output \S+ --quiet --exit-code 0 --skip-dirs \*\*\/node_modules /,
        "Trivy's infrastructure check runs with its own checks, its usage data off");
    like($config, qr/ proxy=http:\/\/127\.0\.0\.1:9\z/, 'and kept off the network');
    my ($vuln) = $r->{log} =~ /^trivy (fs .*)$/m;
    like($vuln, qr/\Afs --scanners vuln --disable-telemetry --skip-version-check --cache-dir \Q$cache\E --format json /,
        "the dependency check runs only Trivy's vulnerability scanner, with FLASHTEAMS_TRIVY_CACHE as its cache");
    like($vuln, qr/ proxy=\z/, 'and may use the network for its database');
    unlike(slurp("$out/findings.json"), qr/THE-FLAGGED-CODE/, "the code the scanners quote is not kept");

    $out = work('full-no-db');
    $r = helper(cwd => $REPO, args => [ 'run', '--kind', 'security', '--mode', 'full', '--rules', $RULES, '--out', $out ],
        env => { FAKE_TRIVY_FS_FAIL => 1 });
    is($r->{status}, 0, 'a failed dependency check does not fail the scan');
    $tools = json_file("$out/tools.json");
    my ($failed) = grep { $_->{name} eq 'trivy-vuln' } @$tools;
    is($failed->{status}, 'failed', 'it is recorded as failed');
    like($failed->{note}, qr/database could not be downloaded: FATAL failed to download vulnerability DB/, "with Trivy's reason");
    ok(scalar(find_rule(json_file("$out/findings.json"), 'trivy:DS-0002')), 'and the other checks still count');
}

# ---------------------------------------------------------------------------
# run: SQL

{
    my $out = work('sql');
    my $r = helper(cwd => $REPO, args => [ 'run', '--kind', 'sql', '--rules', $RULES, '--out', $out ]);
    is($r->{status}, 0, 'a SQL scan runs') or diag($r->{stderr});
    my $findings = json_file("$out/findings.json");
    check_shape($findings, 'sql');
    is_deeply([ sort map { $_->{rule} } @$findings ],
        [ 'ft.db.public-grant', 'ft.security.js.nosql-injection', 'ft.security.js.sql-injection', 'ft.sql.grant-all-to-public', 'gitleaks:generic-api-key' ],
        'the SQL rules, the injection rules about SQL and NoSQL, and secrets in .sql files');
    is(scalar(grep { $_->{tool} ne 'gitleaks' && $_->{category} ne 'sql' } @$findings), 0, 'every code rule finding is in the sql category');
    my ($seed) = find_rule($findings, 'gitleaks:generic-api-key');
    is_deeply([ @$seed{qw(category path)} ], [qw(secret db/seed.sql)], 'a secret in a .sql file stays a secret');
    my ($grant) = find_rule($findings, 'ft.sql.grant-all-to-public');
    is_deeply([ @$grant{qw(severity path line cwe)} ], [qw(high db/schema.sql 2 CWE-732)], 'a SQL rule finding');
    my ($opengrep) = $r->{log} =~ /^opengrep (.*)$/m;
    like($opengrep, qr/--config \Q$RULES\E\/opengrep\/sql --config \Q$RULES\E\/opengrep\/security /, 'the SQL rules and the security rules run');
    unlike($r->{log}, qr/^trivy/m, 'Trivy does not run');
    is_deeply([ map { $_->{name} } @{ json_file("$out/tools.json") } ], [qw(gitleaks opengrep)], 'the SQL audit lists gitleaks and opengrep');
    like($r->{stdout}, qr/^FlashTeams SQL scan of the whole repository$/m, 'the summary says it was a SQL scan');
}

# ---------------------------------------------------------------------------
# run: without rules, without a scanner, with semgrep, and refused

{
    my $out = work('no-rules');
    my $r = helper(cwd => $REPO, args => [ 'run', '--kind', 'security', '--out', $out ]);
    is($r->{status}, 0, 'a scan without rules runs');
    my $tools = json_file("$out/tools.json");
    is_deeply([ (map { "$_->{name} $_->{status}" } @$tools)[ 0, 1 ] ], [ 'gitleaks ran', 'opengrep skipped' ], 'opengrep is skipped');
    is($tools->[1]{note}, 'FlashTeams rules not downloaded', 'because the rules were not downloaded');
    like($tools->[0]{note}, qr/its own rules only/, "gitleaks runs its own rules only");
    is(scalar(() = $r->{log} =~ /^gitleaks /mg), 1, 'once');
    is(json_file("$out/scan.json")->{rules_version}, undef, 'and no rules version is recorded');

    $out = work('missing');
    $r = helper(cwd => $REPO, fakes => fakes('no-gitleaks', qw(opengrep trivy)), args => [ 'run', '--kind', 'security', '--rules', $RULES, '--out', $out ]);
    is($r->{status}, 0, 'a scan with a scanner missing runs');
    my ($gitleaks) = grep { $_->{name} eq 'gitleaks' } @{ json_file("$out/tools.json") };
    is_deeply([ @$gitleaks{qw(status version)} ], [ 'missing', undef ], 'the missing scanner is recorded as missing');
    like($gitleaks->{note}, qr/install gitleaks/, 'with how to install it');
    is(scalar(grep { $_->{tool} eq 'gitleaks' } @{ json_file("$out/findings.json") }), 0, 'and nothing is made up for it');

    $out = work('semgrep');
    $r = helper(cwd => $REPO, fakes => fakes('semgrep', qw(gitleaks semgrep)), args => [ 'run', '--kind', 'security', '--rules', $RULES, '--out', $out ]);
    is($r->{status}, 0, 'semgrep stands in for opengrep');
    my ($semgrep) = grep { $_->{name} eq 'semgrep' } @{ json_file("$out/tools.json") };
    is_deeply([ @$semgrep{qw(status version)} ], [qw(ran 1.99.0)], 'and is recorded as semgrep');
    ok(scalar(grep { $_->{tool} eq 'semgrep' } @{ json_file("$out/findings.json") }), 'its findings are its own');
    my ($line) = $r->{log} =~ /^semgrep (.*)$/m;
    like($line, qr/ --metrics=off /, 'semgrep runs with its metrics off');
    unlike($line, qr/--taint-intrafile/, 'and without the opengrep-only option');

    my $plain = "$TMP/not-a-repo";
    make_path($plain);
    $r = helper(cwd => $plain, args => [ 'run', '--kind', 'security', '--out', work('nowhere') ]);
    is($r->{status}, 1, 'run needs a git working tree');
    like($r->{stderr}, qr/inside a git working tree/, 'and says so');
    $r = helper(cwd => $REPO, args => [ 'run', '--kind', 'security', '--out', "$REPO/scan-out" ]);
    is($r->{status}, 1, 'run keeps the work folder outside the repository');
    like($r->{stderr}, qr/outside the repository/, 'and says why');
    ok(!-e "$REPO/scan-out", 'and makes nothing there');
    $r = helper(cwd => $REPO, args => [ 'run', '--kind', 'security', '--path', '../elsewhere', '--out', work('elsewhere') ]);
    is($r->{status}, 2, 'run scans only folders inside the repository');
    $r = helper(cwd => $REPO, args => [ 'run', '--kind', 'secrets', '--out', work('bad-kind') ]);
    is($r->{status}, 2, 'run knows its kinds');

    $out = work('folder');
    write_json("$FIXTURES/trivy-config-k8s.json", { Results => [ { Target => 'deploy.yaml', Misconfigurations => [
        { ID => 'KSV-0002', Title => 'A check in the folder', Severity => 'MEDIUM', Status => 'FAIL', CauseMetadata => { StartLine => 2 } } ] } ] });
    $r = helper(cwd => $REPO, args => [ 'run', '--kind', 'security', '--mode', 'full', '--path', 'k8s/', '--rules', $RULES, '--out', $out ],
        env => { FAKE_TRIVY_CONFIG => "$FIXTURES/trivy-config-k8s.json" });
    is($r->{status}, 0, 'run scans one folder');
    is(json_file("$out/scan.json")->{path}, 'k8s', 'the folder is recorded as given, without the slash');
    like($r->{log}, qr/^gitleaks dir k8s /m, 'each scanner gets the folder');
    my ($inside) = find_rule(json_file("$out/findings.json"), 'trivy:KSV-0002');
    is($inside && $inside->{path}, 'k8s/deploy.yaml', "Trivy's names inside the folder become paths from the root");
    like($r->{stdout}, qr/of k8s\/$/m, 'the summary names the folder');
}

# ---------------------------------------------------------------------------
# payload

my $NOTES = "$TMP/notes.json";
write_file("$TMP/summary.md", "Two problems to fix first.\n");
write_file("$TMP/report.md", "# Security audit of $REPO\n\nThe key in $REPO/src/config.js and in $TMP/home/x.\n");
git($REPO, 'remote', 'add', 'origin', 'https://someone:t0ken-value@example.com/org/shop.git');

sub payload {
    my ($out, @more) = @_;
    my $r = helper(cwd => $REPO, args => [ 'payload', '--out', $out, '--summary-file', "$TMP/summary.md", '--report-file', "$TMP/report.md", @more ]);
    return ($r, json_file("$out/payload.json"));
}

{
    my $out = $QUICK{out};
    my $findings = $QUICK{findings};
    my ($r, $payload) = payload($out, '--kind', 'security');
    is($r->{status}, 0, 'payload builds the payload') or diag($r->{stderr});
    is($r->{stdout}, "$out/payload.json\n" . scalar(@$findings) . ' findings (' . join(', ', map { my $s = $_; "$s " . scalar(grep { $_->{severity} eq $s } @$findings) } qw(critical high medium low info)) . ")\n",
        'payload prints where it is and the counts');
    is_deeply([ sort keys %$payload ], [ sort qw(kind mode repository scanned_path rules_version tools summary report_markdown findings truncated) ],
        'the payload has exactly the fields record_code_scan takes');
    is_deeply([ @$payload{qw(kind mode scanned_path rules_version truncated)} ], [ 'security', 'quick', '', 'abc123def456', 0 ],
        'kind, mode, folder and rules version from the scan');
    my $commit = git($REPO, 'rev-parse', 'HEAD');
    chomp $commit;
    is_deeply($payload->{repository}, { remote_url => 'https://example.com/org/shop.git', branch => 'main', commit => $commit, dirty => JSON::PP::false },
        "git's facts, with the user name and password taken out of the remote address");
    is_deeply($payload->{findings}, $findings, 'the findings as the scan found them');
    is_deeply([ map { $_->{name} } @{ $payload->{tools} } ], [qw(gitleaks opengrep trivy-config trivy-vuln)], 'and the tools');
    is($payload->{summary}, 'Two problems to fix first.', 'the summary');
    is($payload->{report_markdown}, "# Security audit of shop\n\nThe key in src/config.js and in ~/x.", 'the report, with no folder of this computer in it');
    my $text = slurp("$out/payload.json");
    unlike($text, qr/\Q$TMP\E/, 'the payload names no folder of this computer');
    unlike($text, qr/someone|t0ken-value/, 'nor the user name or password in the remote');

    # Changes not committed make the checkout dirty, but only inside the folder scanned.
    write_file("$REPO/src/server.js", $SOURCE{'src/server.js'} . "// changed\n");
    (undef, $payload) = payload($out, '--kind', 'security');
    is($payload->{repository}{dirty}, JSON::PP::true, 'a change not committed makes the checkout dirty');
    write_file("$REPO/src/server.js", $SOURCE{'src/server.js'});
    write_file("$REPO/untracked.txt", "new\n");
    (undef, $payload) = payload($out, '--kind', 'security');
    is($payload->{repository}{dirty}, JSON::PP::true, 'so does a new file');
    unlink("$REPO/untracked.txt");
    (undef, $payload) = payload($out, '--kind', 'security');
    is($payload->{repository}{dirty}, JSON::PP::false, 'and the checkout is clean again without them');

    git($REPO, 'checkout', '-q', '--detach');
    (undef, $payload) = payload($out, '--kind', 'security');
    is($payload->{repository}{branch}, undef, 'a detached checkout has no branch');
    is($payload->{repository}{commit}, $commit, 'but has its commit');
    git($REPO, 'checkout', '-q', 'main');

    # The notes: dismissed findings go, notes replace the words, and added
    # findings get a fingerprint from their rule, path and title.
    my ($sql) = grep { $findings->[$_]{rule} eq 'ft.security.js.sql-injection' } 0 .. $#$findings;
    my ($plain) = grep { $findings->[$_]{rule} eq 'custom.rule-without-metadata' } 0 .. $#$findings;
    write_json($NOTES, {
        dismiss => [ $plain + 1 ],
        notes   => { $sql + 1 => { detail => "The id comes straight from the address bar, in $REPO/src/server.js.", recommendation => 'Use db.query(sql, [id]).' } },
        add     => [
            { category => 'security', severity => 'high', title => 'Admin routes have no auth check', path => './src/admin.js', line => 3,
              rule => 'agent.security.missing-auth', detail => 'Anyone can call them.', recommendation => 'Add the auth middleware.' },
            { category => 'architecture', severity => 'low', title => 'One module does everything' },
        ],
    });
    ($r, $payload) = payload($out, '--kind', 'security', '--notes', $NOTES);
    is($r->{status}, 0, 'payload reads the notes') or diag($r->{stderr});
    like($r->{stdout}, qr/, 1 dismissed, 2 added\n\z/, 'and says what they changed');
    is(scalar(@{ $payload->{findings} }), scalar(@$findings) + 1, 'one dismissed, two added');
    ok(!grep({ $_->{rule} eq 'custom.rule-without-metadata' } @{ $payload->{findings} }), 'the dismissed finding is left out');
    my ($noted) = grep { $_->{rule} eq 'ft.security.js.sql-injection' } @{ $payload->{findings} };
    is_deeply([ @$noted{qw(detail recommendation fingerprint)} ],
        [ 'The id comes straight from the address bar, in src/server.js.', 'Use db.query(sql, [id]).', $findings->[$sql]{fingerprint} ],
        'a note replaces the detail and recommendation, and keeps the fingerprint');
    my ($added) = grep { $_->{rule} eq 'agent.security.missing-auth' } @{ $payload->{findings} };
    is_deeply($added, { fingerprint => substr(sha256_hex("agent.security.missing-auth\nsrc/admin.js\nAdmin routes have no auth check"), 0, 32),
        category => 'security', tool => 'agent', rule => 'agent.security.missing-auth', severity => 'high', path => 'src/admin.js', line => 3,
        title => 'Admin routes have no auth check', detail => 'Anyone can call them.', recommendation => 'Add the auth middleware.', cwe => undef },
        'an added finding, from the agent');
    my ($bare) = grep { $_->{title} eq 'One module does everything' } @{ $payload->{findings} };
    is_deeply([ @$bare{qw(rule path line detail)} ], [ 'agent.architecture', undef, undef, '' ], 'an added finding needs only a category, severity and title');
    check_shape($payload->{findings}, 'payload with notes');

    for my $bad (
        [ { dismiss => [999] }, qr/the scan has findings #1 to/, 'a finding number the scan does not have' ],
        [ { add => [ { category => 'style', severity => 'low', title => 'x' } ] }, qr/category 'style'/, 'an unknown category' ],
        [ { add => [ { category => 'security', severity => 'urgent', title => 'x' } ] }, qr/severity 'urgent'/, 'an unknown severity' ],
        [ { add => [ { category => 'security', severity => 'low', title => 'x', path => '/etc/passwd' } ] }, qr/relative to the repository root/, 'an absolute path' ],
        [ { add => [ { category => 'security', severity => 'low', title => 'x', path => '../x' } ] }, qr/without \.\./, 'a path out of the repository' ],
        [ { add => [ { category => 'security', severity => 'low', title => '' } ] }, qr/no title/, 'no title' ],
        [ { remove => [1] }, qr/keys this does not read: remove/, 'a key it does not read' ],
    ) {
        write_json($NOTES, $bad->[0]);
        my ($refused) = payload($out, '--kind', 'security', '--notes', $NOTES);
        is($refused->{status}, 1, "payload refuses notes with $bad->[2]");
        like($refused->{stderr}, $bad->[1], 'and says why');
    }

    ($r) = payload($out, '--kind', 'sql');
    is($r->{status}, 1, 'payload refuses a kind the scan was not');
    ($r) = payload($out, '--kind', 'security', '--mode', 'full');
    is($r->{status}, 1, 'or a mode it was not');

    # The summary and report caps.
    write_file("$TMP/long-summary.md", 'word ' x 2000);
    write_file("$TMP/long-report.md", Encode::encode('UTF-8', "\x{20ac}" x 50000));
    $r = helper(cwd => $REPO, args => [ 'payload', '--out', $out, '--kind', 'security', '--summary-file', "$TMP/long-summary.md", '--report-file', "$TMP/long-report.md" ]);
    is($r->{status}, 0, 'payload cuts a long summary and report');
    $payload = json_file("$out/payload.json");
    is(length($payload->{summary}), 4000, 'the summary to 4,000 characters');
    my $report_bytes = length(Encode::encode('UTF-8', $payload->{report_markdown}));
    cmp_ok($report_bytes, '<=', 100000, 'the report to 100,000 bytes');
    cmp_ok($report_bytes, '>', 99000, 'and not much less');
    like($r->{stdout}, qr/The summary was cut/, 'and says so');
}

# 500 findings at most, the most severe kept, and the rest counted.
{
    my $out = work('many');
    make_path($out);
    my @severities = ((('critical') x 100), (('high') x 100), (('medium') x 100), (('low') x 300));
    my @findings = map {
        { fingerprint => sprintf('%032x', $_), category => 'hotspot', tool => 'opengrep', rule => 'r', severity => $severities[$_],
          path => 'src/server.js', line => $_ + 1, title => "Finding $_", detail => '', recommendation => '', cwe => undef }
    } 0 .. 599;
    write_json("$out/findings.json", \@findings);
    write_json("$out/tools.json", []);
    write_json("$out/scan.json", { kind => 'security', mode => 'full', path => '', rules_version => 'v1', root => $REPO });
    my ($r, $payload) = payload($out, '--kind', 'security');
    is($r->{status}, 0, 'payload builds a payload from 600 findings');
    is(scalar(@{ $payload->{findings} }), 500, 'it keeps 500');
    is($payload->{truncated}, 100, 'and counts the 100 left out');
    is(scalar(grep { $_->{severity} eq 'low' } @{ $payload->{findings} }), 200, 'the least severe are the ones left out');
    like($r->{stdout}, qr/100 less severe left out \(truncated\)/, 'and says so');
    ($r, $payload) = payload($out, '--kind', 'security', '--max-findings', 10);
    is_deeply([ scalar(@{ $payload->{findings} }), $payload->{truncated} ], [ 10, 590 ], '--max-findings keeps fewer');
}

# An architecture review: no scan, only the agent's findings, in a
# repository with no commits yet.
{
    my $fresh = "$TMP/fresh";
    make_path($fresh);
    git($fresh, 'init', '-q');
    write_file("$fresh/app.js", "console.log(1);\n");
    my $out = work('architecture');
    write_json($NOTES, { add => [ { category => 'architecture', severity => 'high', title => 'Everything leans on one module', path => 'app.js',
        rule => 'architecture.hub' } ] });
    my $r = helper(cwd => $fresh, args => [ 'payload', '--out', $out, '--kind', 'architecture', '--summary-file', "$TMP/summary.md",
        '--report-file', "$TMP/report.md", '--notes', $NOTES ]);
    is($r->{status}, 0, 'payload builds an architecture review with no scan') or diag($r->{stderr});
    my $payload = json_file("$out/payload.json");
    is_deeply([ @$payload{qw(kind mode rules_version scanned_path truncated)} ], [ 'architecture', undef, undef, '', 0 ],
        'no mode and no rules');
    is_deeply($payload->{tools}, [], 'no tools');
    is_deeply([ map { $_->{rule} } @{ $payload->{findings} } ], ['architecture.hub'], 'only the added findings');
    is($payload->{repository}{commit}, undef, 'a repository with no commits has no commit');
    is($payload->{repository}{remote_url}, undef, 'nor a remote');
    is($payload->{repository}{dirty}, JSON::PP::true, 'and its new file makes it dirty');
}

# ---------------------------------------------------------------------------
# send

{
    my $out = $QUICK{out};
    payload($out, '--kind', 'security');
    my $payload = json_file("$out/payload.json");
    my $answer = qq({"success": true, "scan_id": "scan-1", "counts": {"high": 2}, "new_since_last": 3, "fixed_since_last": 1, "url": "https://flashteams.ai/x"}\n);
    write_file("$TMP/ft-answer", $answer);
    my $r = helper(cwd => $REPO, args => [ 'send', '--out', $out ]);
    is($r->{status}, 0, 'send records the scan');
    is($r->{stdout}, $answer, "and prints the flashteams command's answer as it is");
    like($r->{stderr}, qr/a note on stderr/, "the command's errors reach the agent too");
    my @args = split /\0/, slurp("$TMP/ft-args");
    my %given = map { /\A--([a-z_]+)=(.*)\z/s ? ($1 => $2) : () } @args;
    is($args[0], 'record_code_scan', 'send runs record_code_scan');
    is_deeply([ @args[ -2 .. -1 ] ], [ '--findings', '-' ], 'with the findings on standard input, last');
    is_deeply([ sort keys %given ], [ sort qw(kind mode repository scanned_path rules_version tools summary report_markdown truncated) ],
        'every other field as an argument of its own');
    is_deeply([ @given{qw(kind mode scanned_path rules_version truncated)} ], [ 'security', 'quick', '', 'abc123def456', 0 ], 'text and numbers as they are');
    is_deeply($JSON->decode($given{repository}), $payload->{repository}, 'the repository as JSON');
    is_deeply($JSON->decode($given{tools}), $payload->{tools}, 'the tools as JSON');
    is(Encode::decode('UTF-8', $given{report_markdown}), $payload->{report_markdown}, 'the report as it is, newlines and all');
    is_deeply($JSON->decode(slurp("$TMP/ft-stdin")), $payload->{findings}, 'the findings on standard input');

    $r = helper(cwd => $REPO, args => [ 'send', '--out', $out, '--product-id', '0b6f8a4e-1111-2222-3333-444455556666' ]);
    @args = split /\0/, slurp("$TMP/ft-args");
    ok(grep({ $_ eq '--product_id=0b6f8a4e-1111-2222-3333-444455556666' } @args), 'send passes the product chosen');

    my $refusal = qq({"success": false, "reason": "repository_not_linked", "products": [{"id": "p1", "name": "Shop"}]}\n);
    write_file("$TMP/ft-answer", $refusal);
    for my $code (1, 3, 4, 5) {
        $r = helper(cwd => $REPO, args => [ 'send', '--out', $out ], env => { FAKE_FT_EXIT => $code });
        is($r->{status}, $code, "send exits $code when the command does");
    }
    $r = helper(cwd => $REPO, args => [ 'send', '--out', $out ], env => { FAKE_FT_EXIT => 1 });
    is($r->{stdout}, $refusal, "a refusal's answer reaches stdout");

    my $elsewhere = fakes('elsewhere', 'flashteams');
    $r = helper(cwd => $REPO, fakes => fakes('none'), args => [ 'send', '--out', $out ], env => { FLASHTEAMS_BIN => "$elsewhere/flashteams" });
    is($r->{status}, 0, 'FLASHTEAMS_BIN names the command');
    $r = helper(cwd => $REPO, fakes => fakes('none'), args => [ 'send', '--out', $out ], env => { FLASH_CONSOLE_BIN => $elsewhere });
    is($r->{status}, 0, "or it is found in Flash Console's folder");
    $r = helper(cwd => $REPO, fakes => fakes('none'), args => [ 'send', '--out', $out ]);
    is($r->{status}, 3, 'send exits 3 without the flashteams command');
    like($r->{stderr}, qr/MCP tools/, 'and points to the MCP tools');
    $r = helper(cwd => $REPO, args => [ 'send', '--out', $out ], env => { FLASHTEAMS_BIN => 'flashteams' });
    is($r->{status}, 3, 'FLASHTEAMS_BIN must be a full path');
    $r = helper(cwd => $REPO, args => [ 'send', '--out', work('empty') ]);
    is($r->{status}, 1, 'send needs a payload');

    my $arch = "$OUT/architecture";
    write_file("$TMP/ft-answer", $answer);
    $r = helper(cwd => $REPO, args => [ 'send', '--out', $arch ]);
    my %arch = map { /\A--([a-z_]+)=/ ? ($1 => 1) : () } split /\0/, slurp("$TMP/ft-args");
    ok(!$arch{mode} && !$arch{rules_version}, 'mode and rules_version are left out when empty');
}

# ---------------------------------------------------------------------------
# Fingerprints through a whole scan: lines added above keep them, repeats
# of one line keep theirs apart.

{
    my $before = $QUICK{findings};
    my %old = map { ("$_->{rule} " . ($_->{path} // '') . ' ' . ($_->{line} // '')) => $_->{fingerprint} } @$before;
    my @evals = grep { $_->{rule} eq 'ft.hotspot.js.eval-dynamic-code' } @$before;
    is(scalar(@evals), 2, 'the same line twice is two findings');
    isnt($evals[0]{fingerprint}, $evals[1]{fingerprint}, 'with fingerprints of their own');

    for my $file ('src/server.js', 'src/repeat.js') {
        write_file("$REPO/$file", "// a new first line\n// and another\n$SOURCE{$file}");
    }
    git($REPO, 'commit', '-q', '-am', 'move');
    write_fixtures(shift => 2);
    my $out = work('moved');
    my $r = helper(cwd => $REPO, args => [ 'run', '--kind', 'security', '--rules', $RULES, '--out', $out ]);
    is($r->{status}, 0, 'the scan runs again after lines moved');
    my $after = json_file("$out/findings.json");
    my ($sql) = find_rule($after, 'ft.security.js.sql-injection');
    is($sql->{line}, 11, 'the finding moved down two lines');
    is($sql->{fingerprint}, $old{'ft.security.js.sql-injection src/server.js 9'}, 'and kept its fingerprint');
    my @moved = grep { $_->{rule} eq 'ft.hotspot.js.eval-dynamic-code' } @$after;
    is_deeply([ map { $_->{fingerprint} } @moved ], [ map { $_->{fingerprint} } @evals ], 'the repeats kept theirs too');
    my ($key) = find_rule($after, 'gitleaks:aws-access-token');
    is($key->{fingerprint}, $old{'gitleaks:aws-access-token src/config.js 3'}, 'and the secret kept its own');
}

# ---------------------------------------------------------------------------
# No secret's value anywhere the helper wrote or printed.

{
    my @files;
    for my $dir (@WORK, "$TMP/rules-cache") {
        next unless -d $dir;
        find({ no_chdir => 1, wanted => sub { push @files, $_ if -f $_ } }, $dir);
    }
    ok(scalar(@files) > 10, 'the helper wrote files to check');
    my @leaks = grep { my $text = slurp($_); grep { index($text, $_) >= 0 } $SECRET, $SECRET2, $PASSWORD } @files;
    is("@leaks", '', 'no secret in any file the helper wrote');
    my @printed = grep { my $text = $_; grep { index($text, $_) >= 0 } $SECRET, $SECRET2, $PASSWORD } @OUTPUTS;
    is(scalar(@printed), 0, 'and none in anything it printed');
    my @fields = grep { slurp($_) =~ /"(?:Secret|Match)"/ } @files;
    is("@fields", '', "gitleaks' Secret and Match fields are never kept");
    my @raw = grep { m{/\.raw-} } @files;
    is("@raw", '', "the scanners' reports are deleted");
    opendir(my $dh, "$TMP/tmp");
    is_deeply([ grep { !/\A\.\.?\z/ } readdir($dh) ], [], "the helper's own temporary files are gone");
}

done_testing();
