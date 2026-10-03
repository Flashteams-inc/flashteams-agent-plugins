#!/usr/bin/perl
# Runs the hook the way each agent runs it, for every event both agents
# send, against a throwaway socket that stands in for Flash Console, and
# checks what arrives: the JSON line, the caps, the cleaning, the flags, and
# that the hook stays silent and quick when Flash Console is not there.

use strict;
use warnings;
use utf8;

use Cwd qw(abs_path);
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
  v agent event session_id cwd pane project query response summary tool_name
  tool_input plugin_version error_type error_message subagent interrupted
);

# A project folder with a git repository, worked in from a subfolder.
my $PROJECT = "$TMP/work/my-app";
make_path("$PROJECT/.git", "$PROJECT/src");
my $CWD = "$PROJECT/src";

my $LISTENER = listen_on($SOCKET);

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

# Runs one hook. Options: agent, hook, input (a hash is encoded as JSON),
# env (undef removes a variable), command (instead of the agent's hooks
# command), listener (undef for none), keep_stdin_open, ascii.
# Returns exit status, stdout, stderr, the bytes the listener received, and
# how long the hook ran.
sub run_hook {
    my (%opt) = @_;
    my $agent = $opt{agent} // 'claude';
    my @command = $opt{command}
      ? @{ $opt{command} }
      : ('sh', "$PLUGIN{$agent}/hooks/flashteams-hook.sh", $agent, $opt{hook});
    my $listener = exists $opt{listener} ? $opt{listener} : $LISTENER;

    my $input = $opt{input} // '';
    if (ref $input) {
        $input = $opt{ascii} ? JSON::PP->new->ascii->canonical->encode($input) : $JSON->encode($input);
    }

    local %ENV = (
        PATH                       => $ENV{PATH},
        HOME                       => $TMP,
        FLASH_CONSOLE_AGENT_SOCKET => $SOCKET,
        %{ $opt{env} || {} },
    );
    delete $ENV{$_} for grep { !defined $ENV{$_} } keys %ENV;

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
            $status = $? >> 8;
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
        unlike($event->{$key}, qr/[\x00-\x1f\x7f]/, "$name: no control characters in $key");
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
        { event => 'session_start' },
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

    my $main = claude('PostToolUse', { %tool, agent_type => 'reviewer' }, name => 'claude --agent main thread tool');
    ok(!exists $main->{subagent}, 'claude main thread under --agent: no subagent field');

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
    'SessionStart' => [{ source => 'startup' }, { event => 'session_start' }],
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
    ok(!exists $sub->{pane}, 'codex subagent tool: no pane');

    is(codex('PreToolUse', { tool_name => 'Bash', tool_input => { command => 'ls' } }, name => 'codex PreToolUse Bash'),
        undef, 'codex PreToolUse for other tools: nothing sent');
    is(codex('SubagentStop', { agent_id => 'sub-1' }, name => 'codex SubagentStop'),
        undef, 'codex hooks the plugin does not use: nothing sent');
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

sub quiet {
    my ($name, %opt) = @_;
    my $run = run_hook(agent => 'claude', hook => 'Stop', input => { %CLAUDE_INPUT, hook_event_name => 'Stop' },
        env => { %PANE, %{ $opt{env} || {} } }, %opt{qw(listener command)});
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
