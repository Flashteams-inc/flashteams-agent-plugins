#!/usr/bin/perl
# Runs the hook the way each agent runs it, with the command from its hooks
# configuration, for every event both agents send, against a throwaway
# socket that stands in for Flash Console, and checks what arrives: the JSON
# line, the caps, the cleaning, the flags, and that the hook stays silent and
# quick when Flash Console is not there, when the plugin folder has gone, and
# when the shell comes with options already on.

use strict;
use warnings;
use utf8;

use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use IO::Handle;
use IO::Select;
use IO::Socket::UNIX;
use IPC::Open3 qw(open3);
use JSON::PP;
use POSIX qw(WNOHANG);
use Socket qw(SOCK_STREAM);
use Symbol qw(gensym);
use Test::More;
use Time::HiRes qw(time sleep);

binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw(output failure_output todo_output);
$SIG{PIPE} = 'IGNORE';

my $ROOT = abs_path("$FindBin::Bin/..");
my %PLUGIN = (
    claude => "$ROOT/plugins/claude/flashteams",
    codex  => "$ROOT/plugins/codex/flashteams",
);
my $HOOK_PL = "$ROOT/shared/hooks/flashteams-hook.pl";

# Unix socket paths are short (about 100 bytes), so the work happens in /tmp.
my $TMP = tempdir('ftap-XXXXXX', DIR => '/tmp', CLEANUP => 1);
my $SOCKET = "$TMP/agent.sock";
my $JSON = JSON::PP->new->utf8->canonical;

my $VERSION = do {
    open(my $fh, '<', "$PLUGIN{claude}/.claude-plugin/plugin.json") or die $!;
    local $/;
    decode_json(<$fh>)->{version};
};

my %ALLOWED = map { $_ => 1 } qw(
  v agent event session_id cwd pane project source query response summary
  tool_name tool_input plugin_version error_type error_message subagent
  subagent_id interrupted
);

# Characters no field may carry: control characters, line and paragraph
# separators, the marks that reorder text, and the characters that take no
# space.
my @INVISIBLE = map { chr } 0x061C, 0x200B .. 0x200F, 0x2060 .. 0x2064, 0xFEFF;
my $UNSAFE = qr/[\x00-\x1f\x7f-\x9f\x{061C}\x{200B}-\x{200F}\x{2028}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}]/;

# Each agent's hooks configuration: the command it runs for each hook, and
# the variable that holds the plugin's folder in that command.
my %ROOT_VARIABLE = (claude => 'CLAUDE_PLUGIN_ROOT', codex => 'PLUGIN_ROOT');
my %COMMAND;
for my $agent (sort keys %PLUGIN) {
    open(my $fh, '<', "$PLUGIN{$agent}/hooks/hooks.json") or die $!;
    my $config = do { local $/; decode_json(<$fh>) };
    for my $hook (keys %{ $config->{hooks} }) {
        $COMMAND{$agent}{$hook} = $config->{hooks}{$hook}[0]{hooks}[0]{command};
    }
}

# A project folder with a git repository, worked in from a subfolder.
my $PROJECT = "$TMP/work/my-app";
make_path("$PROJECT/.git", "$PROJECT/src");
my $CWD = "$PROJECT/src";

my $LISTENER = listen_on($SOCKET);

sub write_file {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or die "$path: $!";
    print $fh $text;
    close($fh) or die "$path: $!";
    return;
}

sub listen_on {
    my ($path, $backlog) = @_;
    unlink($path);
    my $listener = IO::Socket::UNIX->new(
        Type   => SOCK_STREAM,
        Local  => $path,
        Listen => $backlog // 16,
    ) or die "cannot listen on $path: $!";
    chmod(0600, $path);
    return $listener;
}

# What an agent runs for a hook: the command from its hooks configuration,
# through sh, with the plugin's folder in the agent's variable. A hook the
# plugin does not register gets the same command with its own name, as if it
# were registered.
sub agent_command {
    my ($agent, $hook, $root) = @_;
    my $command = $COMMAND{$agent}{$hook} // ($COMMAND{$agent}{Stop} =~ s/ Stop\z/ $hook/r);
    return (['sh', '-c', $command], { $ROOT_VARIABLE{$agent} => $root // $PLUGIN{$agent} });
}

# Runs one hook. Options: agent, hook, input (a hash is encoded as JSON),
# env (undef removes a variable), root (the plugin folder the agent's command
# names), command (instead of the agent's command), listener (undef for
# none), keep_stdin_open, ascii.
# Returns exit status (or "signal N" when a signal ended it), stdout, stderr,
# the bytes the listener received, and how long the hook ran.
sub run_hook {
    my (%opt) = @_;
    my $agent = $opt{agent} // 'claude';
    my ($command, $agent_env) = $opt{command} ? ($opt{command}, {}) : agent_command($agent, $opt{hook}, $opt{root});
    my @command = @$command;
    my $listener = exists $opt{listener} ? $opt{listener} : $LISTENER;

    my $input = $opt{input} // '';
    if (ref $input) {
        $input = $opt{ascii} ? JSON::PP->new->ascii->canonical->encode($input) : $JSON->encode($input);
    }

    my %env = (
        PATH                       => $ENV{PATH},
        HOME                       => $TMP,
        FLASH_CONSOLE_AGENT_SOCKET => $SOCKET,
        %$agent_env,
        %{ $opt{env} || {} },
    );
    delete $env{$_} for grep { !defined $env{$_} } keys %env;
    # The environment holds bytes: text with wide characters goes in as UTF-8.
    utf8::encode($env{$_}) for grep { utf8::is_utf8($env{$_}) } keys %env;
    local %ENV = %env;

    my $started = time;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @command);
    $in->autoflush(1);
    $in->blocking(0);

    my $readers = IO::Select->new($out, $err);
    $readers->add($listener) if $listener;
    my %got = (out => '', err => '');
    my %clients;
    my $sent = 0;
    my $stdin_open = 1;
    my ($status, $ended);
    my $deadline = $started + 15;

    my $finish_stdin = sub {
        return unless $stdin_open;
        close($in);
        $stdin_open = 0;
    };
    $finish_stdin->() if !length($input) && !$opt{keep_stdin_open};

    while (time < $deadline) {
        if (!defined $ended && waitpid($pid, WNOHANG) == $pid) {
            $status = $? & 127 ? 'signal ' . ($? & 127) : $? >> 8;
            $ended = time;
            $finish_stdin->();
        }
        last if defined $ended && !$readers->exists($out) && !$readers->exists($err) && !%clients;

        my $writers = IO::Select->new;
        $writers->add($in) if $stdin_open && $sent < length($input);
        my ($can_read, $can_write) = IO::Select->select($readers, $writers, undef, 0.02);
        for my $fh (@{ $can_write || [] }) {
            my $n = syswrite($in, $input, 65536, $sent);
            if (defined $n) {
                $sent += $n;
            }
            elsif (!$!{EAGAIN}) {
                $sent = length($input);    # the hook stopped reading
            }
            $finish_stdin->() if $sent >= length($input) && !$opt{keep_stdin_open};
        }
        for my $fh (@{ $can_read || [] }) {
            if ($listener && $fh == $listener) {
                my $client = $listener->accept or next;
                $clients{ fileno($client) } = [$client, ''];
                $readers->add($client);
                next;
            }
            my $buffer;
            my $n = sysread($fh, $buffer, 65536);
            next if !defined $n && $!{EAGAIN};
            if (!$n) {
                $readers->remove($fh);
                next;
            }
            if ($fh == $out) { $got{out} .= $buffer }
            elsif ($fh == $err) { $got{err} .= $buffer }
            else { $clients{ fileno($fh) }[1] .= $buffer }
        }
        for my $key (keys %clients) {
            my ($client, $data) = @{ $clients{$key} };
            next if $readers->exists($client);
            $got{data} .= $data;
            delete $clients{$key};
        }
    }
    if (!defined $ended) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        $status = 'killed';
        $ended = time;
    }

    # Connections the hook made but this loop never got to accept.
    if ($listener) {
        $listener->blocking(0);
        while (my $client = $listener->accept) {
            $client->blocking(1);
            local $/;
            my $data = <$client>;
            $got{data} .= $data // '';
        }
        $listener->blocking(1);
    }

    return {
        status  => $status,
        stdout  => $got{out},
        stderr  => $got{err},
        data    => $got{data} // '',
        seconds => $ended - $started,
    };
}

# Checks a run was quiet and successful, and returns the one event it sent,
# or undef when it sent none.
sub event_of {
    my ($run, $name) = @_;
    is($run->{status}, 0, "$name: exits 0");
    is($run->{stdout}, '', "$name: nothing on stdout");
    is($run->{stderr}, '', "$name: nothing on stderr");
    return undef if $run->{data} eq '';
    like($run->{data}, qr/\A[^\n]+\n\z/, "$name: one line");
    cmp_ok(length($run->{data}), '<=', 8192, "$name: at most 8192 bytes");
    my $event = eval { $JSON->decode($run->{data}) };
    ok($event, "$name: valid JSON") or diag($run->{data});
    return undef unless $event;
    my @unknown = grep { !$ALLOWED{$_} } sort keys %$event;
    is("@unknown", '', "$name: only protocol fields");
    for my $key (grep { !ref $event->{$_} } keys %$event) {
        unlike($event->{$key}, $UNSAFE, "$name: no control or invisible characters in $key");
    }
    return $event;
}

# JSON with its keys in the order given, the way the agents write it: the
# session and working folder first, the large values last.
sub ordered_json {
    my @pairs = @_;
    my $json = JSON::PP->new->utf8->canonical->allow_nonref;
    my @members;
    while (my ($key, $value) = splice(@pairs, 0, 2)) {
        push @members, $json->encode($key) . q{:} . $json->encode($value);
    }
    return q[{] . join(q{,}, @members) . q[}];
}

sub hook_event {
    my (%opt) = @_;
    my $name = $opt{name} // "$opt{agent} $opt{hook}";
    return event_of(run_hook(%opt), $name);
}

# Expected fields every event from a run carries.
sub common {
    my ($agent, $session) = @_;
    return (
        v              => 1,
        agent          => $agent,
        session_id     => $session,
        cwd            => $CWD,
        project        => 'my-app',
        plugin_version => $VERSION,
    );
}

# ---------------------------------------------------------------------------
# Claude Code

my %CLAUDE_INPUT = (
    session_id      => 'abc123',
    transcript_path => '/Users/me/.claude/projects/app/abc123.jsonl',
    cwd             => $CWD,
    permission_mode => 'default',
);
my %PANE = (FLASH_CONSOLE_PANE => 'pane-42');

sub claude {
    my ($hook, $fields, %opt) = @_;
    return hook_event(
        agent => 'claude',
        hook  => $hook,
        input => { %CLAUDE_INPUT, hook_event_name => $hook, %{ $fields || {} } },
        env   => { %PANE, %{ $opt{env} || {} } },
        %opt{qw(name ascii)},
    );
}

my %claude_cases = (
    'SessionStart' => [
        { source => 'startup', model => 'claude-opus-5' },
        { event => 'session_start', source => 'startup' },
    ],
    'UserPromptSubmit' => [
        { prompt => "Write a function\nto parse CSV files" },
        { event => 'prompt_submit', query => 'Write a function to parse CSV files' },
    ],
    'PreToolUse' => [
        {
            tool_name  => 'AskUserQuestion',
            tool_input => {
                questions => [
                    {
                        question    => 'Which framework?',
                        header      => 'Framework',
                        options     => [{ label => 'React' }, { label => 'Vue' }],
                        multiSelect => JSON::PP::false,
                    },
                ],
            },
            tool_use_id => 'toolu_01',
        },
        { event => 'question_asked', summary => 'Which framework?' },
    ],
    'PostToolUse' => [
        {
            tool_name     => 'Bash',
            tool_input    => { command => 'npm test', description => 'Run the tests' },
            tool_response => { stdout => "all passed\n", stderr => '' },
            tool_use_id   => 'toolu_02',
        },
        {
            event      => 'tool_complete',
            tool_name  => 'Bash',
            tool_input => '{"command":"npm test","description":"Run the tests"}',
        },
    ],
    'PostToolUseFailure' => [
        {
            tool_name    => 'Bash',
            tool_input   => { command => 'npm test' },
            tool_use_id  => 'toolu_03',
            error        => "Exit code 1\nError: Cannot find module 'express'",
            is_interrupt => JSON::PP::false,
        },
        { event => 'tool_complete', tool_name => 'Bash', tool_input => '{"command":"npm test"}' },
    ],
    'PermissionRequest' => [
        {
            tool_name  => 'Bash',
            tool_input => { command => 'rm -rf node_modules', description => 'Remove node_modules directory' },
        },
        {
            event      => 'permission_request',
            tool_name  => 'Bash',
            tool_input => '{"command":"rm -rf node_modules","description":"Remove node_modules directory"}',
            summary    => 'Remove node_modules directory',
        },
    ],
    'Stop' => [
        { stop_hook_active => JSON::PP::false, last_assistant_message => "Done.\n\nThe tests pass." },
        { event => 'stop', response => 'Done. The tests pass.' },
    ],
    'StopFailure' => [
        {
            error                  => 'rate_limit',
            error_details          => '429 Too Many Requests',
            last_assistant_message => 'API Error: Rate limit reached',
        },
        { event => 'stop_failure', error_type => 'rate_limit', error_message => 'API Error: Rate limit reached' },
    ],
);

for my $hook (sort keys %claude_cases) {
    my ($input, $expected) = @{ $claude_cases{$hook} };
    my $event = claude($hook, $input);
    is_deeply($event, { common('claude', 'abc123'), pane => 'pane-42', %$expected }, "claude $hook: event")
      or diag(explain($event));
}

my %notifications = (
    permission_prompt      => 'permission_request',
    idle_prompt            => 'idle_prompt',
    elicitation_dialog     => 'question_asked',
    elicitation_url_dialog => 'question_asked',
);
for my $type (sort keys %notifications) {
    my $event = claude(
        'Notification',
        { notification_type => $type, message => "Claude needs\tyou", title => 'Attention' },
        name => "claude Notification $type",
    );
    is_deeply(
        $event,
        { common('claude', 'abc123'), pane => 'pane-42', event => $notifications{$type}, summary => 'Claude needs you' },
        "claude Notification $type: event"
    );
}

is(claude('Notification', { notification_type => 'auth_success', message => 'Signed in' }, name => 'claude auth_success'),
    undef, 'claude Notification auth_success: nothing sent');

is(claude('PreToolUse', { tool_name => 'Bash', tool_input => { command => 'ls' } }, name => 'claude PreToolUse Bash'),
    undef, 'claude PreToolUse for other tools: nothing sent');

is(claude('SubagentStop', { agent_id => 'a1', agent_type => 'Explore' }, name => 'claude SubagentStop'),
    undef, 'claude hooks the plugin does not use: nothing sent');

{
    my $event = claude('Stop', { stop_hook_active => JSON::PP::true, last_assistant_message => 'Finished.' },
        name => 'claude Stop, stop hook active');
    is($event->{event}, 'stop', 'claude Stop is sent even when stop_hook_active is true');
}

{
    my $event = claude('StopFailure', { error => 'server_error', error_details => '500 Internal Server Error' },
        name => 'claude StopFailure without rendered text');
    is($event->{error_message}, '500 Internal Server Error', 'claude StopFailure falls back to error_details');
}

{
    my $event = claude(
        'PermissionRequest',
        { tool_name => 'AskUserQuestion', tool_input => { questions => [{ question => 'Ship it?' }] } },
        name => 'claude PermissionRequest for a question'
    );
    is($event->{event},   'question_asked', 'claude question permission is reported as a question');
    is($event->{summary}, 'Ship it?',       'claude question permission carries the question');
}

{
    my $event = claude(
        'PermissionRequest',
        { tool_name => 'Write', tool_input => { file_path => '/tmp/x.txt', content => 'hello' } },
        name => 'claude PermissionRequest without a description'
    );
    is($event->{summary}, '/tmp/x.txt', 'claude permission summary falls back to the file');
}

{
    my %tool = (tool_name => 'Read', tool_input => { file_path => '/etc/hosts' }, tool_response => 'x');
    my $sub = claude('PostToolUse', { %tool, agent_id => 'agent-7', agent_type => 'Explore' },
        name => 'claude subagent tool');
    is($sub->{subagent}, JSON::PP::true, 'claude subagent tool: subagent is true');
    ok(JSON::PP::is_bool($sub->{subagent}), 'claude subagent tool: subagent is a JSON boolean');
    is($sub->{subagent_id}, 'agent-7', "claude subagent tool: subagent_id is the subagent's own id");

    my $main = claude('PostToolUse', { %tool, agent_type => 'reviewer' }, name => 'claude --agent main thread tool');
    ok(!exists $main->{subagent},    'claude main thread under --agent: no subagent field');
    ok(!exists $main->{subagent_id}, 'claude main thread under --agent: no subagent_id field');

    my $nopane = claude('Stop', {}, env => { FLASH_CONSOLE_PANE => undef }, name => 'claude without a pane');
    ok(!exists $nopane->{pane}, 'claude outside Flash Console tabs: no pane field');
    is($nopane->{event}, 'stop', 'claude outside Flash Console tabs: still sent');
}

# ---------------------------------------------------------------------------
# Codex

my %CODEX_INPUT = (
    session_id      => 'thr_123',
    turn_id         => 'turn_9',
    transcript_path => '/Users/me/.codex/sessions/rollout.jsonl',
    cwd             => $CWD,
    model           => 'gpt-5-codex',
    permission_mode => 'default',
);

sub codex {
    my ($hook, $fields, %opt) = @_;
    return hook_event(
        agent => 'codex',
        hook  => $hook,
        input => { %CODEX_INPUT, hook_event_name => $hook, %{ $fields || {} } },
        # Visible to the shared background server, and never to be sent.
        env => { FLASH_CONSOLE_PANE => 'pane-from-another-terminal', %{ $opt{env} || {} } },
        %opt{qw(name)},
    );
}

my %codex_cases = (
    'SessionStart' => [{ source => 'startup' }, { event => 'session_start', source => 'startup' }],
    'UserPromptSubmit' => [
        { prompt => 'Fix the failing build' },
        { event => 'prompt_submit', query => 'Fix the failing build' },
    ],
    'PreToolUse' => [
        {
            tool_name   => 'request_user_input',
            tool_use_id => 'call_1',
            tool_input  => {
                questions => [
                    { id => 'db', header => 'Database', question => 'Which database should I use?', options => [] },
                ],
            },
        },
        { event => 'question_asked', summary => 'Which database should I use?' },
    ],
    'PostToolUse' => [
        {
            tool_name     => 'Bash',
            tool_use_id   => 'call_2',
            tool_input    => { command => 'cargo test' },
            tool_response => "test result: ok\n",
        },
        { event => 'tool_complete', tool_name => 'Bash', tool_input => '{"command":"cargo test"}' },
    ],
    'PermissionRequest' => [
        {
            tool_name  => 'Bash',
            tool_input => { command => 'rm -rf build', description => 'Remove the build folder' },
        },
        {
            event      => 'permission_request',
            tool_name  => 'Bash',
            tool_input => '{"command":"rm -rf build","description":"Remove the build folder"}',
            summary    => 'Remove the build folder',
        },
    ],
    'Stop' => [
        { stop_hook_active => JSON::PP::false, last_assistant_message => 'Build fixed.' },
        { event => 'stop', response => 'Build fixed.' },
    ],
    'Interrupt' => [{}, { event => 'stop', interrupted => JSON::PP::true }],
);

for my $hook (sort keys %codex_cases) {
    my ($input, $expected) = @{ $codex_cases{$hook} };
    my $event = codex($hook, $input);
    is_deeply($event, { common('codex', 'thr_123'), %$expected }, "codex $hook: event, with no pane")
      or diag(explain($event));
}

{
    my $event = codex('PermissionRequest', { tool_name => 'apply_patch', tool_input => { command => '*** Begin Patch' } },
        name => 'codex PermissionRequest without a description');
    is($event->{summary}, '*** Begin Patch', 'codex permission summary falls back to the command');

    my $sub = codex('PostToolUse',
        { tool_name => 'Bash', tool_input => { command => 'ls' }, agent_id => 'sub-1', agent_type => 'worker' },
        name => 'codex subagent tool');
    is($sub->{subagent}, JSON::PP::true, 'codex subagent tool: subagent is true');
    is($sub->{subagent_id}, 'sub-1', "codex subagent tool: subagent_id is the subagent's own id");
    ok(!exists $sub->{pane}, 'codex subagent tool: no pane');

    # Codex's prompt hook input can name a subagent too.
    my $prompt = codex('UserPromptSubmit', { prompt => 'Look into the logs', agent_id => 'sub-2', agent_type => 'worker' },
        name => 'codex subagent prompt');
    is($prompt->{subagent_id}, 'sub-2', "codex subagent prompt: subagent_id is the subagent's own id");

    is(codex('PreToolUse', { tool_name => 'Bash', tool_input => { command => 'ls' } }, name => 'codex PreToolUse Bash'),
        undef, 'codex PreToolUse for other tools: nothing sent');
    is(codex('SubagentStop', { agent_id => 'sub-1' }, name => 'codex SubagentStop'),
        undef, 'codex hooks the plugin does not use: nothing sent');
}

# ---------------------------------------------------------------------------
# Which subagent an event came from: agent_id from the hook input, sent as
# subagent_id beside the subagent flag, and never on the main agent's events.

{
    my %agent = (claude => \&claude, codex => \&codex);
    my %tool = (tool_name => 'Bash', tool_input => { command => 'ls' }, tool_response => 'a');
    for my $name (sort keys %agent) {
        my $run = $agent{$name};
        for my $hook (qw(SessionStart UserPromptSubmit PostToolUse PermissionRequest Stop)) {
            my $event = $run->($hook, { %tool, prompt => 'hi', agent_type => 'reviewer' }, name => "$name main agent $hook");
            ok($event && !exists $event->{subagent_id}, "$name main agent $hook: no subagent_id");
            ok($event && !exists $event->{subagent},    "$name main agent $hook: no subagent flag");
        }

        my $long = $run->('PostToolUse', { %tool, agent_id => 'a' x 129 }, name => "$name over-long agent_id");
        is($long->{subagent}, JSON::PP::true, "$name: an agent_id over 128 characters still marks a subagent");
        ok(!exists $long->{subagent_id}, "$name: an agent_id over 128 characters is not sent");

        my $odd = $run->('PostToolUse', { %tool, agent_id => "a\x07g\x{1b}ent\x{202E}-9" }, name => "$name odd agent_id");
        is($odd->{subagent_id}, 'agent-9', "$name: subagent_id is cleaned like any id");

        my $blank = $run->('PostToolUse', { %tool, agent_id => "\x{202E}\x07" }, name => "$name invisible agent_id");
        is($blank->{subagent}, JSON::PP::true, "$name: an agent_id with nothing visible still marks a subagent");
        ok(!exists $blank->{subagent_id}, "$name: an agent_id with nothing visible is not sent");

        for my $value ('', undef, 7) {
            my $label = defined $value ? $value eq '' ? 'empty' : 'numeric' : 'null';
            my $none = $run->('PostToolUse', { %tool, agent_id => $value }, name => "$name $label agent_id");
            ok(!exists $none->{subagent} && !exists $none->{subagent_id}, "$name: a $label agent_id is no subagent");
        }
    }

    # When the line is too long, subagent_id stays with the other ids.
    my $big = claude(
        'PermissionRequest',
        {
            cwd        => '/' . ("\x{1F680}" x 1000),
            session_id => 's' x 128,
            agent_id   => "\x{1F916}" x 128,
            tool_name  => 'Bash',
            tool_input => { command => 'x' x 9000 },
        },
        env  => { FLASH_CONSOLE_PANE => 'p' x 128 },
        name => 'largest subagent event'
    );
    is($big->{subagent_id}, "\x{1F916}" x 128, 'largest subagent event: subagent_id survives');
    is($big->{subagent},    JSON::PP::true,     'largest subagent event: subagent survives');
}

# ---------------------------------------------------------------------------
# Why a session started: each agent's own word, passed on as given, and only
# on session_start.

{
    my %agent = (claude => \&claude, codex => \&codex);
    for my $name (sort keys %agent) {
        my $run = $agent{$name};
        # The values both agents document, and one only Claude Code sends.
        for my $source (qw(startup resume clear compact fork)) {
            my $event = $run->('SessionStart', { source => $source }, name => "$name SessionStart from $source");
            is($event->{source}, $source, "$name SessionStart from $source: source passed on");
        }

        my $none = $run->('SessionStart', {}, name => "$name SessionStart without a source");
        is($none->{event}, 'session_start', "$name SessionStart without a source: still sent");
        ok(!exists $none->{source}, "$name SessionStart without a source: no source field");

        my $odd = $run->('SessionStart', { source => "new\x07-thing\x{202E}" }, name => "$name SessionStart odd source");
        is($odd->{source}, 'new-thing', "$name SessionStart: a source the plugin does not know is passed on, cleaned");

        my $long = $run->('SessionStart', { source => 's' x 65 }, name => "$name SessionStart over-long source");
        ok(!exists $long->{source}, "$name SessionStart: a source over 64 characters is dropped");

        my $number = $run->('SessionStart', { source => 7 }, name => "$name SessionStart numeric source");
        ok(!exists $number->{source}, "$name SessionStart: a source that is not text is dropped");

        my $prompt = $run->('UserPromptSubmit', { prompt => 'hi', source => 'startup' }, name => "$name prompt with a source");
        ok(!exists $prompt->{source}, "$name: only session_start carries source");
    }

    # When the line is too long, the project name goes before the source.
    my $deep = '/' . ("\x{1F680}" x 1000);
    my $big = claude(
        'SessionStart',
        { cwd => $deep, session_id => 's' x 128, source => 'resume' },
        env  => { FLASH_CONSOLE_PANE => 'p' x 128 },
        name => 'largest session_start'
    );
    is($big->{source}, 'resume', 'largest session_start: the source survives');
    is($big->{cwd},    $deep,    'largest session_start: the working folder survives');
    ok(!exists $big->{project}, 'largest session_start: the project name goes first');
}

# ---------------------------------------------------------------------------
# Excerpts: one line, no control characters, at most 320 characters.

{
    my $event = claude('UserPromptSubmit', { prompt => "line one\n\n\tline two\r\n" . ('word ' x 400) },
        name => 'long prompt');
    my $query = $event->{query};
    is(length($query), 320, 'long prompt: capped at 320 characters');
    like($query, qr/\Aline one line two word word/, 'long prompt: whitespace collapsed to single spaces');
    like($query, qr/\x{2026}\z/, 'long prompt: marked as cut');
    unlike($query, qr/  /, 'long prompt: no double spaces');

    my $exact = claude('UserPromptSubmit', { prompt => 'x' x 320 }, name => 'prompt of exactly 320');
    is($exact->{query}, 'x' x 320, 'a prompt of exactly 320 characters is kept whole');

    my $over = claude('UserPromptSubmit', { prompt => 'y' x 321 }, name => 'prompt of 321');
    is($over->{query}, ('y' x 319) . "\x{2026}", 'a prompt of 321 characters is cut to 320');

    my $controls = claude('UserPromptSubmit',
        { prompt => "a\x07b\tc\r\nd\x1b[0me\x{202E}f\x{0}g\x{7f}h\x{85}i" }, name => 'control characters');
    is($controls->{query}, 'ab c d[0mefgh i', 'control characters and reordering marks are removed');

    my $unicode = claude('UserPromptSubmit', { prompt => "Caf\x{e9} \x{2615} \x{1F680} \"quoted\" back\\slash" },
        ascii => 1, name => 'escaped unicode');
    is($unicode->{query}, "Caf\x{e9} \x{2615} \x{1F680} \"quoted\" back\\slash",
        'escaped characters, accents and emoji survive');

    my $reply = claude('Stop', { last_assistant_message => ("\x{1F600}" x 400) }, name => 'long emoji reply');
    is(length($reply->{response}), 320, 'long reply: capped at 320 characters, not bytes');

    my $session = claude('SessionStart', { session_id => "abc\x{1b}]0;title\x07" }, name => 'control characters in an id');
    is($session->{session_id}, 'abc]0;title', 'ids lose their control characters');

    my $long_id = claude('SessionStart', { session_id => 'i' x 129 }, name => 'over-long id');
    ok(!exists $long_id->{session_id}, 'an id over 128 characters is dropped, not cut');
}

# ---------------------------------------------------------------------------
# Characters that take no space or reorder text: U+061C, U+200B to U+200F,
# U+2060 to U+2064 and U+FEFF are removed from every text field, as control
# characters are.

{
    for my $char (@INVISIBLE) {
        my $code = sprintf('U+%04X', ord $char);
        my $event = claude('UserPromptSubmit', { prompt => "a${char}b ${char} c" }, name => "$code in a prompt");
        is($event->{query}, 'ab c', "$code is removed from an excerpt, and the spaces around it collapse");
        my $id = claude('SessionStart', { session_id => "abc${char}123" }, name => "$code in an id");
        is($id->{session_id}, 'abc123', "$code is removed from an id");
    }

    my $all = join('', @INVISIBLE);
    my $tool = claude(
        'PermissionRequest',
        {
            session_id => "abc${all}123",
            cwd        => "$PROJECT/s${all}rc",
            agent_id   => "agent${all}-7",
            tool_name  => "Ba${all}sh",
            tool_input => { command => "rm -rf${all} build", description => "${all}Remove the build" },
        },
        env  => { FLASH_CONSOLE_PANE => "pane${all}-42" },
        name => 'every invisible character in every field of a tool event'
    );
    is_deeply(
        $tool,
        {
            common('claude', 'abc123'),
            pane        => 'pane-42',
            event       => 'permission_request',
            subagent    => JSON::PP::true,
            subagent_id => 'agent-7',
            tool_name   => 'Bash',
            tool_input  => '{"command":"rm -rf build","description":"Remove the build"}',
            summary     => 'Remove the build',
        },
        'every invisible character is removed from every field of a tool event'
    ) or diag(explain($tool));

    my %cases = (
        SessionStart => [{ source => "re${all}sume" }, { source => 'resume' }],
        Stop         => [{ last_assistant_message => "Do${all}ne." }, { response => 'Done.' }],
        StopFailure  => [
            { error => "rate${all}_limit", last_assistant_message => "${all}API Error${all}" },
            { error_type => 'rate_limit', error_message => 'API Error' },
        ],
        Notification => [
            { notification_type => "idle${all}_prompt", message => "Waiting ${all} for you" },
            { summary => 'Waiting for you' },
        ],
    );
    for my $hook (sort keys %cases) {
        my ($input, $expected) = @{ $cases{$hook} };
        my $event = claude($hook, $input, name => "every invisible character in claude $hook");
        is($event->{$_}, $expected->{$_}, "every invisible character is removed from $_") for sort keys %$expected;
    }

    my $question = codex(
        'PreToolUse',
        { tool_name => 'request_user_input', tool_input => { questions => [{ question => "Which${all} one?" }] } },
        name => 'every invisible character in a codex question'
    );
    is($question->{summary}, 'Which one?', 'every invisible character is removed from a codex question');

    # Characters just outside those ranges stay.
    my $kept = claude('UserPromptSubmit', { prompt => "\x{061B} \x{2027} \x{2030} \x{2070} \x{FEFC}" },
        name => 'neighbours of the removed characters');
    is($kept->{query}, "\x{061B} \x{2027} \x{2030} \x{2070} \x{FEFC}", 'characters just outside the removed ranges stay');
}

# ---------------------------------------------------------------------------
# The 8192-byte limit.

{
    my $deep = '/' . ("\x{1F680}" x 1000);
    my $event = claude(
        'PermissionRequest',
        {
            cwd        => $deep,
            session_id => 's' x 128,
            tool_name  => 'Bash',
            tool_input => { command => ('"\\' x 3000), description => ("\x{1F600}\"" x 2000) },
        },
        env  => { FLASH_CONSOLE_PANE => 'p' x 128 },
        name => 'everything at its largest'
    );
    ok($event, 'everything at its largest: still sent');
    is($event->{event}, 'permission_request', 'everything at its largest: the event survives');
    is($event->{cwd},   $deep,                'everything at its largest: the working folder survives');
    is($event->{session_id}, 's' x 128, 'everything at its largest: the session survives');
}

# ---------------------------------------------------------------------------
# Large input: only the first megabyte is read, and nothing large is decoded.

{
    my $run = run_hook(
        agent => 'claude',
        hook  => 'PostToolUse',
        input => ordered_json(
            session_id      => q{abc123},
            transcript_path => q{/Users/me/.claude/projects/app/abc123.jsonl},
            cwd             => $CWD,
            permission_mode => q{default},
            hook_event_name => q{PostToolUse},
            tool_name       => q{Bash},
            tool_input      => { command => q{cat big.log} },
            tool_response   => { stdout => q{z} x (5 * 1024 * 1024) },
            tool_use_id     => q{toolu_09},
        ),
        env => \%PANE,
    );
    my $event = event_of($run, 'five megabyte tool output');
    is($event->{event},     'tool_complete', 'five megabyte tool output: event sent');
    is($event->{tool_name}, 'Bash',          'five megabyte tool output: tool name read');
    cmp_ok($run->{seconds}, '<', 2.5, 'five megabyte tool output: quick');
}

{
    my $prompt = 'Start of a pasted file. ' . ('{"a":[1,"\\"]"]} ' x 200_000);
    my $run = run_hook(
        agent => 'claude',
        hook  => 'UserPromptSubmit',
        input => ordered_json(
            session_id      => q{abc123},
            transcript_path => q{/Users/me/.claude/projects/app/abc123.jsonl},
            cwd             => $CWD,
            permission_mode => q{default},
            hook_event_name => q{UserPromptSubmit},
            prompt          => $prompt,
        ),
        env   => \%PANE,
    );
    my $event = event_of($run, 'three megabyte prompt');
    like($event->{query}, qr/\AStart of a pasted file\. \{"a":\[1,"\\"\]"\]\}/,
        'three megabyte prompt: the excerpt is its beginning');
    is($event->{session_id}, 'abc123', 'three megabyte prompt: fields before it are read');
    cmp_ok($run->{seconds}, '<', 2.5, 'three megabyte prompt: quick');
}

{
    # A tool input larger than the read limit, written before the fields
    # that follow it: what came before is still read.
    my $input = $JSON->encode({ %CLAUDE_INPUT, hook_event_name => 'PostToolUse', tool_name => 'Write' });
    $input =~ s/\}\z/,"tool_input":{"file_path":"\/tmp\/a {[\\"x","content":"/;
    $input .= ('q' x (2 * 1024 * 1024)) . '"},"tool_response":{}}';
    my $run = run_hook(agent => 'claude', hook => 'PostToolUse', input => $input, env => \%PANE);
    my $event = event_of($run, 'two megabyte tool input');
    is($event->{tool_name}, 'Write', 'two megabyte tool input: tool name read');
    like($event->{tool_input}, qr/\A\{"file_path":"\/tmp\/a \{\[\\"x","content":"qqq/,
        'two megabyte tool input: excerpt of its beginning');
    is(length($event->{tool_input}), 320, 'two megabyte tool input: excerpt capped');
}

{
    my $run = run_hook(
        agent => 'codex',
        hook  => 'PostToolUse',
        input => {
            %CODEX_INPUT,
            hook_event_name => 'PostToolUse',
            tool_name       => 'Bash',
            tool_input      => { command => 'cat huge' },
            tool_response   => 'y' x (3 * 1024 * 1024),
        },
    );
    my $event = event_of($run, 'codex three megabyte tool output');
    is($event->{tool_name}, 'Bash', 'codex three megabyte tool output: tool name read');
}

# ---------------------------------------------------------------------------
# Odd input and arguments: still exit 0, still quiet.

{
    my $event = hook_event(agent => 'claude', hook => 'Stop', input => 'this is not json', env => \%PANE,
        name => 'input that is not JSON');
    is_deeply(
        $event,
        { v => 1, agent => 'claude', event => 'stop', pane => 'pane-42', plugin_version => $VERSION },
        'input that is not JSON: a bare event'
    );

    my $named = hook_event(
        agent   => 'claude',
        command => ['sh', "$PLUGIN{claude}/hooks/flashteams-hook.sh", 'claude'],
        input   => { %CLAUDE_INPUT, hook_event_name => 'Stop' },
        name    => 'event name taken from the input',
    );
    is($named->{event}, 'stop', 'without an event argument, hook_event_name decides');

    for my $args ([], ['someone-else', 'Stop'], ['claude', 'NoSuchHook']) {
        my $run = run_hook(
            command => ['sh', "$PLUGIN{claude}/hooks/flashteams-hook.sh", @$args],
            input   => { %CLAUDE_INPUT },
        );
        is(event_of($run, "arguments (@$args)"), undef, "arguments (@$args): nothing sent");
    }
}

{
    my $run = run_hook(agent => 'claude', hook => 'Stop', keep_stdin_open => 1, env => \%PANE);
    my $event = event_of($run, 'input that never ends');
    is($event->{event}, 'stop', 'input that never ends: the event is still sent');
    cmp_ok($run->{seconds}, '<', 2.5, 'input that never ends: gives up waiting');
}

# ---------------------------------------------------------------------------
# When Flash Console is not there, or not answering: exit 0, quietly, fast.

# Runs a hook, by default claude Stop, and checks it was quiet and quick.
# Options: agent, hook, root, env, listener and command, as for run_hook,
# and within, the most seconds it may take.
sub quiet {
    my ($name, %opt) = @_;
    my $agent = $opt{agent} // 'claude';
    my $hook  = $opt{hook}  // 'Stop';
    my %input = $agent eq 'claude' ? %CLAUDE_INPUT : %CODEX_INPUT;
    my $run = run_hook(agent => $agent, hook => $hook, input => { %input, hook_event_name => $hook },
        env => { %PANE, %{ $opt{env} || {} } }, %opt{qw(listener command root)});
    is($run->{status}, 0,  "$name: exits 0");
    is($run->{stdout}, '', "$name: nothing on stdout");
    is($run->{stderr}, '', "$name: nothing on stderr");
    cmp_ok($run->{seconds}, '<', $opt{within} // 1.5, "$name: quick");
    return $run;
}

quiet('no socket', env => { FLASH_CONSOLE_AGENT_SOCKET => "$TMP/missing.sock" }, listener => undef);

{
    my $stale = listen_on("$TMP/stale.sock");
    close($stale);    # the file stays behind, as after a crash
    ok(-S "$TMP/stale.sock", 'a stale socket file is left');
    quiet('refused socket', env => { FLASH_CONSOLE_AGENT_SOCKET => "$TMP/stale.sock" }, listener => undef);
}

{
    open(my $fh, '>', "$TMP/plain-file") or die $!;
    print $fh "not a socket\n";
    close($fh);
    quiet('a plain file where the socket goes', env => { FLASH_CONSOLE_AGENT_SOCKET => "$TMP/plain-file" },
        listener => undef);
}

{
    # Never accepted, never read.
    my $silent = listen_on("$TMP/silent.sock");
    quiet('a socket that never answers', env => { FLASH_CONSOLE_AGENT_SOCKET => "$TMP/silent.sock" },
        listener => undef);
    close($silent);
}

{
    # Every waiting place taken, so connecting cannot finish.
    my $busy = listen_on("$TMP/busy.sock", 1);
    my @waiting;
    for (1 .. 256) {
        my $client = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => "$TMP/busy.sock", Timeout => 0.05)
          or last;
        push @waiting, $client;
    }
    ok(scalar(@waiting), 'the busy socket has a full queue');
    quiet('a socket with a full queue', env => { FLASH_CONSOLE_AGENT_SOCKET => "$TMP/busy.sock" },
        listener => undef);
    close($_) for @waiting;
    close($busy);
}

{
    my $empty = "$TMP/no-programs";
    make_path($empty);
    my $run = quiet(
        'no Perl',
        env      => { PATH => $empty },
        command  => ['/bin/sh', "$PLUGIN{claude}/hooks/flashteams-hook.sh", 'claude', 'Stop'],
        listener => $LISTENER,
    );
    is($run->{data}, '', 'no Perl: nothing sent');
}

# A hook program that cannot run: the starter still exits 0 and says
# nothing, so the agent never shows a hook error. Each program runs from a
# throwaway copy of the starter, never by changing the real files.
{
    my %programs = (
        'a hook program that does not compile' => "use strict;\nmy \$broken = (;\n",
        'a hook program that dies'              => "die qq{the hook broke\\n};\n",
        'a hook program that exits non-zero'    => "print qq{noise\\n};\nprint STDERR qq{trouble\\n};\nexit 3;\n",
        'a hook program killed by a signal'     => "kill 'KILL', \$\$;\nsleep 5;\n",
    );
    my $n = 0;
    for my $name (sort keys %programs) {
        my $dir = "$TMP/broken-" . ++$n . '/hooks';
        make_path($dir);
        copy("$ROOT/shared/hooks/flashteams-hook.sh", "$dir/flashteams-hook.sh") or die $!;
        write_file("$dir/flashteams-hook.pl", $programs{$name});

        my $direct = run_hook(command => ['perl', "$dir/flashteams-hook.pl", 'claude', 'Stop'], listener => undef);
        isnt($direct->{status}, 0, "$name: really fails when Perl runs it directly");

        my $run = quiet($name, command => ['sh', "$dir/flashteams-hook.sh", 'claude', 'Stop'], listener => $LISTENER);
        is($run->{data}, '', "$name: nothing sent");
    }
}

# A Perl without a module the program needs. PERL5LIB puts a stand-in for
# JSON::PP first in Perl's search path, and loading it fails exactly the way
# a missing module does.
{
    my $lib = "$TMP/perl-without-json-pp";
    make_path("$lib/JSON");
    write_file("$lib/JSON/PP.pm", "die qq{Can't locate JSON/PP.pm in \\\@INC (a stand-in for a missing module)\\n};\n");

    my $direct = run_hook(command => ['perl', $HOOK_PL, 'claude', 'Stop'], env => { PERL5LIB => $lib },
        input => { %CLAUDE_INPUT, hook_event_name => 'Stop' }, listener => undef);
    isnt($direct->{status}, 0, 'a missing module: Perl alone fails');
    like($direct->{stderr}, qr/Can't locate JSON\/PP\.pm/, 'a missing module: Perl alone complains');

    for my $agent (qw(claude codex)) {
        my $run = quiet(
            "$agent with a missing module",
            env      => { PERL5LIB => $lib },
            command  => ['sh', "$PLUGIN{$agent}/hooks/flashteams-hook.sh", $agent, 'Stop'],
            listener => $LISTENER,
        );
        is($run->{data}, '', "$agent with a missing module: nothing sent");
    }
}

# ---------------------------------------------------------------------------
# A plugin folder that has gone. When Codex updates the plugin it deletes the
# old folder but keeps running the hook commands it read from it, and sh on
# a missing file complains and exits non-zero. So every hook command starts
# the starter through a guard that exits 0 without a word when the starter
# is missing or cannot be read.

{
    my $gone = "$TMP/deleted-plugin";
    my $bare = run_hook(command => ['sh', "$gone/hooks/flashteams-hook.sh", 'claude', 'Stop'], listener => undef);
    isnt($bare->{status}, 0, 'sh on a missing starter really fails');
    isnt($bare->{stderr}, '', 'sh on a missing starter really complains');

    for my $agent (sort keys %COMMAND) {
        # The starter deleted, the Perl program left behind.
        my $no_starter = "$TMP/no-starter-$agent";
        make_path("$no_starter/hooks");
        copy($HOOK_PL, "$no_starter/hooks/flashteams-hook.pl") or die $!;

        # The starter left behind, the Perl program deleted.
        my $no_program = "$TMP/no-program-$agent";
        make_path("$no_program/hooks");
        copy("$ROOT/shared/hooks/flashteams-hook.sh", "$no_program/hooks/flashteams-hook.sh") or die $!;

        my %folders = (
            'a deleted plugin folder'                  => $gone,
            'a plugin folder without a starter'        => $no_starter,
            'a plugin folder without the Perl program' => $no_program,
        );
        for my $what (sort keys %folders) {
            for my $hook (sort keys %{ $COMMAND{$agent} }) {
                my $run = quiet("$agent $hook in $what", agent => $agent, hook => $hook, root => $folders{$what},
                    listener => $LISTENER);
                is($run->{data}, '', "$agent $hook in $what: nothing sent");
            }
        }
    }

    # A starter that cannot be read. Root reads every file, so this only
    # means something for anyone else.
  SKIP: {
        skip 'root can read any file', 10 if $> == 0;
        my $locked = "$TMP/locked-plugin";
        make_path("$locked/hooks");
        copy("$ROOT/shared/hooks/flashteams-hook.sh", "$locked/hooks/flashteams-hook.sh") or die $!;
        copy($HOOK_PL, "$locked/hooks/flashteams-hook.pl") or die $!;
        chmod(0000, "$locked/hooks/flashteams-hook.sh") or die $!;
        for my $agent (sort keys %COMMAND) {
            my $run = quiet("$agent with an unreadable starter", agent => $agent, root => $locked, listener => $LISTENER);
            is($run->{data}, '', "$agent with an unreadable starter: nothing sent");
        }
        chmod(0644, "$locked/hooks/flashteams-hook.sh");
    }
}

# ---------------------------------------------------------------------------
# Shell options the hook inherits. bash turns on every option an exported
# SHELLOPTS names, also when it runs as sh, so errexit, nounset and xtrace
# can reach the guard and the starter from the agent's environment. With
# them on, the starter still exits 0, prints no trace, and sends the event.

SKIP: {
    my ($bash) = grep { -x } map { "$_/bash" } split(/:/, $ENV{PATH}), '/bin';
    skip 'bash is not installed', 1 unless $bash;
    my $bin = "$TMP/bash-as-sh";
    make_path($bin);
    symlink($bash, "$bin/sh") or die "$bin/sh: $!";
    my $path = "$bin:$ENV{PATH}";

    # A copy of the starter with a hook program that fails.
    my $failing = "$TMP/failing-plugin";
    make_path("$failing/hooks");
    copy("$ROOT/shared/hooks/flashteams-hook.sh", "$failing/hooks/flashteams-hook.sh") or die $!;
    write_file("$failing/hooks/flashteams-hook.pl", "exit 3;\n");

    # bash as sh really takes the options, so the checks below mean something.
    my $check = run_hook(
        command  => ['sh', '-c', 'false; echo after'],
        env      => { PATH => $path, SHELLOPTS => 'errexit:xtrace' },
        listener => undef,
    );
    isnt($check->{status}, 0, 'bash as sh takes errexit from SHELLOPTS');
    like($check->{stderr}, qr/^\+ false$/m, 'bash as sh takes xtrace from SHELLOPTS');

    # The agent's own shell, which reads the hook command, is not the
    # plugin's to quiet, so here it runs without the options and passes them
    # to everything the command starts. (A shell that turned them off with
    # set would also take them out of the SHELLOPTS its children get.)
    my $agent_shell = sub {
        my ($agent, $options, $root) = @_;
        my ($command, $root_env) = agent_command($agent, 'Stop', $root);
        return (
            command  => [$command->[0], '-c', "exec env SHELLOPTS=$options $command->[2]"],
            root_env => $root_env,
        );
    };

    for my $options ('errexit:xtrace', 'errexit:nounset:xtrace') {
        my %env = (PATH => $path, SHELLOPTS => $options);
        for my $agent (qw(claude codex)) {
            my %input = $agent eq 'claude' ? %CLAUDE_INPUT : %CODEX_INPUT;
            my %shell = $agent_shell->($agent, $options);
            my $event = hook_event(command => $shell{command}, input => { %input, hook_event_name => 'Stop' },
                env => { %PANE, PATH => $path, %{ $shell{root_env} } }, name => "$agent Stop with SHELLOPTS=$options");
            is($event && $event->{event}, 'stop', "$agent Stop with SHELLOPTS=$options: sent");

            # Hook commands written before the guard start the starter
            # directly, with nothing to hide its stderr.
            my $direct = hook_event(
                command => ['sh', "$PLUGIN{$agent}/hooks/flashteams-hook.sh", $agent, 'Stop'],
                input   => { %input, hook_event_name => 'Stop' },
                env     => { %PANE, %env },
                name    => "$agent starter run directly with SHELLOPTS=$options",
            );
            is($direct && $direct->{event}, 'stop', "$agent starter run directly with SHELLOPTS=$options: sent");

            my %gone = $agent_shell->($agent, $options, "$TMP/deleted-plugin");
            quiet("$agent with a deleted plugin folder and SHELLOPTS=$options", command => $gone{command},
                env => { PATH => $path, %{ $gone{root_env} } }, listener => $LISTENER);
        }
        quiet("a failing hook program with SHELLOPTS=$options",
            command => ['sh', "$failing/hooks/flashteams-hook.sh", 'claude', 'Stop'], env => \%env, listener => $LISTENER);
        quiet("the starter without arguments with SHELLOPTS=$options",
            command => ['sh', "$PLUGIN{claude}/hooks/flashteams-hook.sh"], env => \%env, listener => $LISTENER);
    }
}

# ---------------------------------------------------------------------------
# Where the socket is when FLASH_CONSOLE_AGENT_SOCKET is not set, found the
# same way by the shell starter and by the Perl program.

{
    my $home = "$TMP/home";
    my @places = $^O eq 'darwin'
      ? (["$home/Library/Application Support/Flash Console", {}])
      : (["$TMP/run/flash-console", { XDG_RUNTIME_DIR => "$TMP/run" }],
         ["$home/.local/state/flash-console", { XDG_RUNTIME_DIR => undef }]);
    for my $place (@places) {
        my ($dir, $env) = @$place;
        make_path($dir, { mode => 0700 });
        my $listener = listen_on("$dir/agent.sock");
        for my $via ('starter', 'perl') {
            my @command = $via eq 'starter'
              ? ('sh', "$PLUGIN{claude}/hooks/flashteams-hook.sh", 'claude', 'Stop')
              : ('perl', $HOOK_PL, 'claude', 'Stop');
            my $event = hook_event(
                command  => \@command,
                input    => { %CLAUDE_INPUT, hook_event_name => 'Stop' },
                env      => { FLASH_CONSOLE_AGENT_SOCKET => undef, HOME => $home, %PANE, %$env },
                listener => $listener,
                name     => "default socket in $dir via $via",
            );
            is($event && $event->{event}, 'stop', "default socket in $dir via $via: received");

            my $relative = hook_event(
                command  => \@command,
                input    => { %CLAUDE_INPUT, hook_event_name => 'Stop' },
                env      => { FLASH_CONSOLE_AGENT_SOCKET => 'agent.sock', HOME => $home, %PANE, %$env },
                listener => $listener,
                name     => "relative FLASH_CONSOLE_AGENT_SOCKET via $via",
            );
            is($relative && $relative->{event}, 'stop', "relative FLASH_CONSOLE_AGENT_SOCKET via $via: default used");
        }
        close($listener);
        unlink("$dir/agent.sock");
    }
}

done_testing();
