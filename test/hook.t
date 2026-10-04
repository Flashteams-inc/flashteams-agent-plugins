#!/usr/bin/perl
# Runs the hook the way each agent runs it, with the command from its hooks
# configuration, for every event both agents send, against a throwaway
# socket that stands in for Flash Console, and checks what arrives: the JSON
# line, the caps, the cleaning, the flags, and that the hook stays silent and
# quick when Flash Console is not there, when the plugin folder has gone, and
# when the shell comes with options already on. At a session start the
# stand-in also answers the briefing request, at once, slowly, in pieces,
# badly or not at all, and the checks cover what the agent reads on stdout.

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

# How the stand-in for Flash Console answers a request line (one with an
# "op"), given the decoded request (undef when it is not JSON) and the line:
# a list of steps, each [seconds after the request, bytes to write], after
# which the connection closes; an empty list to close at once without a
# word; or undef to hold the connection open and never answer. A step with
# undef bytes closes the connection there. By default the stand-in closes
# at once, as a Flash Console from before briefings does.
my $OLD_FLASH_CONSOLE = sub { [] };

# Runs one hook. Options: agent, hook, input (a hash is encoded as JSON),
# env (undef removes a variable), root (the plugin folder the agent's command
# names), command (instead of the agent's command), listener (undef for
# none), answer (see above), keep_stdin_open, ascii.
# Returns exit status (or "signal N" when a signal ended it), stdout, stderr,
# the status event bytes the listener received, the requests it received
# (decoded, or the raw line when not JSON), and how long the hook ran.
sub run_hook {
    my (%opt) = @_;
    my $agent = $opt{agent} // 'claude';
    my ($command, $agent_env) = $opt{command} ? ($opt{command}, {}) : agent_command($agent, $opt{hook}, $opt{root});
    my @command = @$command;
    my $listener = exists $opt{listener} ? $opt{listener} : $LISTENER;
    my $answer = $opt{answer} // $OLD_FLASH_CONSOLE;

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
    my %got = (out => '', err => '', data => '', requests => []);
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

    # What one connection carried: a request, or a status event.
    my $record = sub {
        my ($data) = @_;
        my ($line) = $data =~ /\A([^\n]*)/;
        my $request = eval { $JSON->decode($line) };
        if (ref $request eq 'HASH' && exists $request->{op}) {
            push @{ $got{requests} }, $request;
        }
        else {
            $got{data} .= $data;
        }
    };
    my $hang_up = sub {
        my ($key) = @_;
        my $client = delete $clients{$key};
        $readers->remove($client->{sock}) if $readers->exists($client->{sock});
        close($client->{sock});
        $record->($client->{data});
    };

    while (time < $deadline) {
        if (!defined $ended && waitpid($pid, WNOHANG) == $pid) {
            $status = $? & 127 ? 'signal ' . ($? & 127) : $? >> 8;
            $ended = time;
            $finish_stdin->();
        }
        last if defined $ended && !$readers->exists($out) && !$readers->exists($err) && !%clients;

        my $writers = IO::Select->new;
        $writers->add($in) if $stdin_open && $sent < length($input);
        my ($can_read, $can_write) = IO::Select->select($readers, $writers, undef, 0.01);
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
                $clients{ fileno($client) } = { sock => $client, data => '' };
                $readers->add($client);
                next;
            }
            my $buffer;
            my $n = sysread($fh, $buffer, 65536);
            next if !defined $n && $!{EAGAIN};
            if ($fh == $out || $fh == $err) {
                if (!$n) {
                    $readers->remove($fh);
                    next;
                }
                $got{ $fh == $out ? 'out' : 'err' } .= $buffer;
                next;
            }
            my $key = fileno($fh);
            if (!$n) {
                $hang_up->($key);
                next;
            }
            my $client = $clients{$key};
            $client->{data} .= $buffer;

            # A whole request line: decide how to answer it.
            next if $client->{asked} || $client->{data} !~ /\A([^\n]*)\n/;
            my $line = $1;
            my $request = eval { $JSON->decode($line) };
            next unless ref $request eq 'HASH' && exists $request->{op};
            $client->{asked} = time;
            my $steps = $answer->($request, $line);
            if (defined $steps) {
                $client->{steps} = [@$steps];
            }
            else {
                $client->{hold} = 1;
            }
        }

        # Answers that are due.
        for my $key (keys %clients) {
            my $client = $clients{$key};
            next unless $client->{steps};
            while (@{ $client->{steps} } && time >= $client->{asked} + $client->{steps}[0][0]) {
                my (undef, $bytes) = @{ shift @{ $client->{steps} } };
                if (!defined $bytes) {
                    @{ $client->{steps} } = ();
                    last;
                }
                my $done = 0;
                while ($done < length($bytes)) {
                    my $n = syswrite($client->{sock}, $bytes, length($bytes) - $done, $done);
                    last unless $n;    # the hook hung up
                    $done += $n;
                }
            }
            $hang_up->($key) unless @{ $client->{steps} };
        }
    }
    if (!defined $ended) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        $status = 'killed';
        $ended = time;
    }
    $hang_up->($_) for keys %clients;

    # Connections the hook made but this loop never got to accept.
    if ($listener) {
        $listener->blocking(0);
        while (my $client = $listener->accept) {
            $client->blocking(1);
            local $/;
            my $data = <$client>;
            $record->($data // '');
        }
        $listener->blocking(1);
    }

    return {
        status   => $status,
        stdout   => $got{out},
        stderr   => $got{err},
        data     => $got{data},
        requests => $got{requests},
        seconds  => $ended - $started,
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

# ---------------------------------------------------------------------------
# The start-up briefing. At a session start the hook sends the status event,
# then asks Flash Console for a briefing on the same socket and, given a
# good answer within 1.5 seconds, prints it as the one JSON object both
# agents read from a session start hook. Anything else prints nothing.

my $BRIEFING = join("\n",
    q{FlashTeams is available in this session through the flashteams command, using Ada's Flash Console sign-in (Example Co).},
    q{How to use it: every FlashTeams tool is a subcommand: flashteams <tool> --<argument> <value>.},
    q{Current task (chosen in Flash Console): Fix the "sign in" page \ again (task id 7d4c)},
    q{},
    qq{WORKING LOOP\n1. connect_workspace to a project.\n\tIndented, caf\x{e9}, \x{1F680}.},
);

# A good answer to a briefing request: its own id, ok and the text.
sub good_answer {
    my ($request, %fields) = @_;
    return $JSON->encode({ v => 1, id => $request->{id}, ok => JSON::PP::true, text => $BRIEFING, %fields }) . "\n";
}

# A stand-in Flash Console that answers with good_answer after $delay
# seconds, with any fields given in place of the usual ones.
sub answers {
    my ($delay, %fields) = @_;
    return sub { [[$delay, good_answer($_[0], %fields)]] };
}

# Runs a session start the way the agent does. Options: agent, input (more
# input fields), env, answer, command, listener, keep_stdin_open.
sub session_start {
    my (%opt) = @_;
    my $agent = $opt{agent} // 'claude';
    my %input = $agent eq 'claude' ? %CLAUDE_INPUT : %CODEX_INPUT;
    return run_hook(
        agent  => $agent,
        hook   => 'SessionStart',
        input  => { %input, hook_event_name => 'SessionStart', source => 'startup', %{ $opt{input} || {} } },
        env    => { %PANE, %{ $opt{env} || {} } },
        answer => $opt{answer} // answers(0),
        %opt{ grep { exists $opt{$_} } qw(command listener keep_stdin_open) },
    );
}

# Checks a run printed one briefing object and nothing else, and returns
# the briefing's text.
sub briefing_of {
    my ($run, $name) = @_;
    is($run->{status}, 0,  "$name: exits 0");
    is($run->{stderr}, '', "$name: nothing on stderr");
    like($run->{stdout}, qr/\A\{"hookSpecificOutput":\{[^\n]*\}\}\n\z/, "$name: one JSON object on one line");
    my $out = eval { $JSON->decode($run->{stdout}) };
    ok(ref $out eq 'HASH', "$name: stdout is a JSON object") or return undef;
    is_deeply([sort keys %$out], ['hookSpecificOutput'], "$name: only hookSpecificOutput");
    my $specific = ref $out->{hookSpecificOutput} eq 'HASH' ? $out->{hookSpecificOutput} : {};
    is_deeply([sort keys %$specific], [qw(additionalContext hookEventName)], "$name: the two fields agents read");
    is($specific->{hookEventName}, 'SessionStart', "$name: for SessionStart");
    return $specific->{additionalContext};
}

# Checks a run printed nothing, quickly.
sub no_briefing {
    my ($run, $name, $within) = @_;
    is($run->{status}, 0,  "$name: exits 0");
    is($run->{stdout}, '', "$name: nothing on stdout");
    is($run->{stderr}, '', "$name: nothing on stderr");
    cmp_ok($run->{seconds}, '<', $within // 2.2, "$name: quick");
    return $run;
}

# The status event a run sent, decoded.
sub status_of {
    my ($run) = @_;
    return $run->{data} eq '' ? undef : eval { $JSON->decode($run->{data}) };
}

my %REQUEST_FIELDS = map { $_ => 1 } qw(v op id agent cwd pane source);

for my $agent (qw(claude codex)) {
    my $run = session_start(agent => $agent);
    my $text = briefing_of($run, "$agent briefing");
    is($text, $BRIEFING, "$agent briefing: the text as Flash Console sent it, lines, tabs and all");
    cmp_ok($run->{seconds}, '<', 1, "$agent briefing: quick");

    my $status = status_of($run);
    is($status && $status->{event},  'session_start', "$agent briefing: the status event is still sent");
    is($status && $status->{source}, 'startup',       "$agent briefing: the status event keeps its source");

    is(scalar @{ $run->{requests} }, 1, "$agent briefing: one request");
    my $request = $run->{requests}[0];
    my @unknown = grep { !$REQUEST_FIELDS{$_} } sort keys %$request;
    is("@unknown", '', "$agent briefing: only request fields");
    is($request->{v},     1,          "$agent briefing: protocol version 1");
    is($request->{op},    'briefing', "$agent briefing: asks for the briefing");
    like($request->{id},  qr/\A[0-9a-f]{16,64}\z/, "$agent briefing: a random hex id");
    is($request->{agent}, $agent,     "$agent briefing: names the agent");
    is($request->{cwd},   $CWD,       "$agent briefing: the agent's working folder");
    is($request->{source}, 'startup', "$agent briefing: why the session started");
    # Codex runs hooks in a shared background server whose environment may
    # name another terminal's pane, so its requests never name one.
    is($request->{pane}, $agent eq 'claude' ? 'pane-42' : '', "$agent briefing: the pane, from Claude Code only");

    my $again = session_start(agent => $agent);
    isnt($again->{requests}[0]{id}, $request->{id}, "$agent briefing: each request has its own id");

    # The hook as the agent runs it, and the starter run on its own.
    my $direct = run_hook(
        command => ['sh', "$PLUGIN{$agent}/hooks/flashteams-hook.sh", $agent, 'SessionStart'],
        input   => { ($agent eq 'claude' ? %CLAUDE_INPUT : %CODEX_INPUT), hook_event_name => 'SessionStart' },
        env     => \%PANE,
        answer  => answers(0),
    );
    is(briefing_of($direct, "$agent starter on its own"), $BRIEFING, "$agent starter on its own: the briefing");
}

{
    my $nopane = session_start(env => { FLASH_CONSOLE_PANE => undef });
    briefing_of($nopane, 'claude briefing outside a pane');
    is($nopane->{requests}[0]{pane}, '', 'claude briefing outside a pane: an empty pane');

    for my $source (qw(startup resume clear compact fork)) {
        my $run = session_start(input => { source => $source });
        briefing_of($run, "briefing from $source");
        is($run->{requests}[0]{source}, $source, "briefing from $source: source passed on");
    }
    my $none = session_start(input => { source => undef });
    briefing_of($none, 'briefing without a source');
    ok(!exists $none->{requests}[0]{source}, 'briefing without a source: no source field');

    # A working folder the input does not give is the hook's own.
    my $nocwd = session_start(input => { cwd => undef });
    briefing_of($nocwd, 'briefing without a working folder');
    like($nocwd->{requests}[0]{cwd}, qr{\A/}, 'briefing without a working folder: the hook\'s own folder');

    my $deep = '/' . ("\x{1F680}" x 1000);
    my $big = session_start(input => { cwd => $deep, session_id => 's' x 128 }, env => { FLASH_CONSOLE_PANE => 'p' x 128 });
    briefing_of($big, 'briefing from a deep folder');
    is($big->{requests}[0]{cwd}, $deep, 'briefing from a deep folder: the folder is sent whole');
}

# How long a text is to an agent: JavaScript's length, in UTF-16 units, so
# a character past U+FFFF counts as two.
sub utf16_length {
    my ($text) = @_;
    return length($text) + ($text =~ tr/\x{10000}-\x{10FFFF}//);
}

# The text: lines and tabs stay, other line breaks become lines, other
# control characters become a space, invisible characters go, and a
# briefing longer than agents take in one piece is cut at a line end.
{
    my $messy = session_start(answer => answers(0,
        text => "One\r\nTwo\rThree\x07\x1b[0m\x{202E}\x{200B}\x{2028}\x{FEFF}\tFour\x{85}"));
    is(briefing_of($messy, 'messy briefing'), "One\nTwo\nThree [0m\n\tFour\n", 'messy briefing: cleaned');

    # Words either side of a removed character stay apart.
    my %apart = (
        "line one\x{2028}still one\nnext\x07bell" => "line one\nstill one\nnext bell",
        "para one\x{2029}para two"                => "para one\npara two",
        "tab\x0Bvertical\x0Cform feed"            => "tab\nvertical\nform feed",
        "next\x{85}line"                          => "next\nline",
        "null\x00and\x01\x02\x1fcontrols\x7f\x9fend" => "null and controls end",
        "joined\x{200B}word"                      => "joinedword",
    );
    for my $text (sort keys %apart) {
        (my $name = $text) =~ s/([^\x20-\x7e])/sprintf('\\x{%X}', ord $1)/ge;
        (my $want = $apart{$text}) =~ s/\n/ | /g;
        is(briefing_of(session_start(answer => answers(0, text => $text)), "briefing '$name'"), $apart{$text},
            "briefing '$name': $want");
    }

    my $nine = join("\n", ('n' x 99) x 90);
    is(length($nine), 8999, 'a briefing of 8999 characters');
    is(briefing_of(session_start(answer => answers(0, text => $nine)), 'briefing under 9000'), $nine,
        'a briefing under 9000 characters is whole');

    my $limit = 'L' x 10000;
    is(briefing_of(session_start(answer => answers(0, text => $limit)), 'briefing of 10000'), $limit,
        'a briefing of exactly 10000 characters is whole');

    my $long = join("\n", map { sprintf('line %05d %s', $_, 'x' x 80) } 1 .. 500);
    my $cut = briefing_of(session_start(answer => answers(0, text => $long)), 'long briefing');
    cmp_ok(length($cut), '<=', 10000, 'long briefing: at most 10000 characters');
    my ($kept, $more) = $cut =~ /\A(.*\n)\[cut: (\d+) more characters\]\z/s;
    ok(defined $kept, 'long briefing: whole lines, then a note of what was cut');
    is(substr($long, 0, length($kept // '')), $kept, 'long briefing: the start is kept as it was');
    is($more, length($long) - length($kept // ''), 'long briefing: the note counts what was cut');

    my $line = "\x{1F680}" x 20000;
    my $one = briefing_of(session_start(answer => answers(0, text => $line)), 'one long line');
    like($one, qr/\A\x{1F680}+\n\[cut: \d+ more characters\]\z/, 'one long line: cut where it must be, with the note');
    cmp_ok(utf16_length($one), '<=', 10000, 'one long line: at most 10000 UTF-16 units');
    my ($rockets, $left) = $one =~ /\A(\x{1F680}+)\n\[cut: (\d+) more characters\]\z/;
    is($left, 20000 - length($rockets // ''), 'one long line: the note counts what was cut');

    # Agents count the limit in UTF-16 units, as JavaScript does, so a
    # character past U+FFFF, such as an emoji, takes two.
    my $fits = "\x{1F680}" x 5000;
    is(briefing_of(session_start(answer => answers(0, text => $fits)), '5000 emoji'), $fits,
        '5000 emoji, 10000 UTF-16 units: whole');
    my $mixed = ('a' x 9990) . ("\x{1F680}" x 5);
    is(briefing_of(session_start(answer => answers(0, text => $mixed)), '10000 units, mixed'), $mixed,
        'letters and emoji in exactly 10000 UTF-16 units: whole');
    for my $case (["\x{1F680}" x 5001, '5001 emoji'], [$mixed . 'a', 'one unit over, mixed'],
        ["\x{1F680}" x 9500, '9500 emoji'])
    {
        my ($text, $name) = @$case;
        my $cut = briefing_of(session_start(answer => answers(0, text => $text)), $name);
        cmp_ok(utf16_length($cut), '<=', 10000, "$name: cut to at most 10000 UTF-16 units");
        like($cut, qr/\n\[cut: \d+ more characters\]\z/, "$name: with the note");
    }
    my $lines = join("\n", ("\x{1F680}" x 50) x 150);
    my $cut_lines = briefing_of(session_start(answer => answers(0, text => $lines)), 'emoji lines');
    cmp_ok(utf16_length($cut_lines), '<=', 10000, 'emoji lines: at most 10000 UTF-16 units');
    my ($whole_lines) = $cut_lines =~ /\A((?:\x{1F680}{50}\n)+)\[cut: \d+ more characters\]\z/;
    ok(defined $whole_lines, 'emoji lines: cut at a line end');
    cmp_ok(utf16_length($whole_lines // ''), '>', 9800, 'emoji lines: as many whole lines as fit');

    # Just under the 1 MiB answer limit is still read, and cut.
    my $huge = 'h' x (1024 * 1024 - 200);
    my $read = briefing_of(session_start(answer => answers(0, text => $huge)), 'answer just under 1 MiB');
    like($read, qr/\Ah+\n\[cut: \d+ more characters\]\z/, 'answer just under 1 MiB: read and cut');

    # The answer may come in pieces, and without a final newline before the
    # connection closes.
    my $pieces = sub {
        my $whole = good_answer($_[0]);
        return [[0, substr($whole, 0, 10)], [0.3, substr($whole, 10, 50)], [0.6, substr($whole, 60)]];
    };
    is(briefing_of(session_start(answer => $pieces), 'answer in pieces'), $BRIEFING, 'answer in pieces: read whole');
    my $unended = sub { [[0, good_answer($_[0]) =~ s/\n\z//r]] };
    is(briefing_of(session_start(answer => $unended), 'answer without a newline'), $BRIEFING,
        'answer without a newline: read when the connection closes');
    my $more_lines = sub { [[0, good_answer($_[0]) . "not json\n" . good_answer($_[0], text => 'second')]] };
    is(briefing_of(session_start(answer => $more_lines), 'answer with more lines'), $BRIEFING,
        'answer with more lines: only the first counts');

    my $late_ok = session_start(answer => answers(1.0));
    is(briefing_of($late_ok, 'answer after one second'), $BRIEFING, 'answer after one second: in time');
}

# Answers that give no briefing: nothing printed, quickly.
{
    my %bad = (
        'an older Flash Console that closes without a word' => sub { [] },
        'an answer that is not JSON'          => sub { [[0, "FlashTeams is available\n"]] },
        'an answer that is a JSON array'      => sub { [[0, qq([1,2,3]\n)]] },
        'an answer that is a JSON string'     => sub { [[0, qq("text"\n)]] },
        'an answer cut short'                 => sub { [[0, substr(good_answer($_[0]), 0, 40)]] },
        'ok given as a number'                => answers(0, ok => 1),
        'ok false given as a number'          => answers(0, ok => 0, code => 'busy', message => 'Busy.'),
        'ok false given as a string'          => answers(0, ok => 'false', code => 'busy', message => 'Busy.'),
        'a refusal to another request'        => answers(0, ok => JSON::PP::false, id => 'f' x 32, code => 'busy'),
        'a refusal in another version'        => answers(0, ok => JSON::PP::false, v => 2, code => 'busy'),
        'ok given as a string'                => answers(0, ok => 'true'),
        'another request\'s id'               => answers(0, id => 'f' x 32),
        'no id'                               => answers(0, id => undef),
        'another protocol version'            => answers(0, v => 2),
        'no protocol version'                 => answers(0, v => undef),
        'no text'                             => answers(0, text => undef),
        'empty text'                          => answers(0, text => ''),
        'text of only spaces and lines'       => answers(0, text => " \n\t\n "),
        'text of only invisible characters'   => answers(0, text => "\x{200B}\x07\x{FEFF}"),
        'text that is a number'               => answers(0, text => 42),
        'text that is an object'              => answers(0, text => { a => 1 }),
        'a status event in reply'             => sub { [[0, qq({"v":1,"event":"stop"}\n)]] },
        'an answer over 1 MiB'                => answers(0, text => 'o' x (1024 * 1024)),
        'invalid UTF-8'                       => sub { [[0, good_answer($_[0]) =~ s/WORKING/\xff\xfe/r]] },
    );
    for my $name (sort keys %bad) {
        my $run = no_briefing(session_start(answer => $bad{$name}), $name);
        my $status = status_of($run);
        is($status && $status->{event}, 'session_start', "$name: the status event is still sent");
    }

    # A refusal: Flash Console is there but could not brief this session,
    # for example because it is busy. The agent hears that, why, and how to
    # start with the command anyway, never nothing at all.
    my $NOTE = "Flash Console could not send the FlashTeams briefing for this session.";
    my $START = "\nThe flashteams command may still work: run flashteams tools for the list of tools"
      . " and flashteams help <tool> for a tool's arguments.";
    my $refusal = sub {
        my (%fields) = @_;
        return sub { [[0, $JSON->encode({ v => 1, id => $_[0]{id}, ok => JSON::PP::false, %fields }) . "\n"]] };
    };
    my $busy = 'Flash Console is already answering 4 FlashTeams requests. Try again when one finishes.';
    my %refusals = (
        'a busy refusal'                => [{ code => 'busy', message => $busy }, "$NOTE $busy$START"],
        'a refusal on several lines'    => [{ code => 'internal', message => "Something\nwent \x07 wrong.\x{2028}Sorry." },
            "$NOTE Something went wrong. Sorry.$START"],
        'a refusal with only a code'    => [{ code => 'busy' }, "$NOTE Its answer was busy.$START"],
        'a refusal with an odd code'    => [{ code => "Bad\ncode" }, "$NOTE$START"],
        'a refusal with nothing more'   => [{}, "$NOTE$START"],
        'a refusal with an empty message' => [{ code => 'busy', message => " \n " }, "$NOTE Its answer was busy.$START"],
        'a refusal with a number message' => [{ code => 'busy', message => 42 }, "$NOTE Its answer was busy.$START"],
    );
    for my $name (sort keys %refusals) {
        my ($fields, $want) = @{ $refusals{$name} };
        my $run = session_start(answer => $refusal->(%$fields));
        is(briefing_of($run, $name), $want, "$name: a short note for the agent");
        cmp_ok($run->{seconds}, '<', 1, "$name: quick");
        my $status = status_of($run);
        is($status && $status->{event}, 'session_start', "$name: the status event is still sent");
    }
    my $long = 'Why ' x 200;
    my $long_note = briefing_of(session_start(answer => $refusal->(code => 'busy', message => $long)), 'a long refusal');
    my ($why) = ($long_note // '') =~ /\A\Q$NOTE\E (.*)\Q$START\E\z/s;
    ok(defined $why && length($why) <= 320 && $why !~ /\n/, 'a long refusal: its message cut to one short line');
    for my $agent (qw(claude codex)) {
        is(briefing_of(session_start(agent => $agent, answer => $refusal->(code => 'busy', message => $busy)),
            "$agent busy refusal"), "$NOTE $busy$START", "$agent busy refusal: the note");
    }

    # Too slow: the hook gives up at 1.5 seconds and prints nothing.
    for my $case (['an answer after 2.5 seconds', answers(2.5)], ['no answer at all', sub { undef }]) {
        my ($name, $answer) = @$case;
        my $run = no_briefing(session_start(answer => $answer), $name);
        cmp_ok($run->{seconds}, '>=', 1.4, "$name: waits for the answer");
        is(scalar @{ $run->{requests} }, 1, "$name: the request was sent");
    }
    my $drip = sub {
        my $whole = good_answer($_[0]);
        return [map { [0.2 * $_, substr($whole, $_ * 40, 40)] } 0 .. int(length($whole) / 40)];
    };
    no_briefing(session_start(answer => $drip), 'an answer that drips in too slowly');

    # Flash Console not there or not answering.
    no_briefing(session_start(env => { FLASH_CONSOLE_AGENT_SOCKET => "$TMP/missing.sock" }, listener => undef),
        'no socket at a session start', 1);
    no_briefing(session_start(env => { FLASH_CONSOLE_AGENT_SOCKET => "$TMP/stale.sock" }, listener => undef),
        'a refused socket at a session start', 1);
    my $silent = listen_on("$TMP/silent-start.sock");
    no_briefing(session_start(env => { FLASH_CONSOLE_AGENT_SOCKET => "$TMP/silent-start.sock" }, listener => undef),
        'a socket that never accepts at a session start');
    close($silent);

    # Input that never ends and a Flash Console that never answers: the
    # longest a session start can take, well inside the agent's timeout.
    my $longest = no_briefing(session_start(answer => sub { undef }, keep_stdin_open => 1),
        'the slowest session start', 3.5);
}

# Only a session start asks, and only a session start prints, even when
# Flash Console would answer anything.
{
    for my $agent (sort keys %COMMAND) {
        my %input = $agent eq 'claude' ? %CLAUDE_INPUT : %CODEX_INPUT;
        for my $hook (grep { $_ ne 'SessionStart' } sort keys %{ $COMMAND{$agent} }) {
            my $run = run_hook(
                agent  => $agent,
                hook   => $hook,
                input  => { %input, hook_event_name => $hook, tool_name => 'AskUserQuestion', prompt => 'hi' },
                env    => \%PANE,
                answer => answers(0),
            );
            is_deeply($run->{requests}, [], "$agent $hook: no briefing request");
            is($run->{stdout}, '', "$agent $hook: nothing on stdout");
        }
    }

    # A session start named only in the input, not on the command line.
    my $named = run_hook(
        command => ['sh', "$PLUGIN{claude}/hooks/flashteams-hook.sh", 'claude'],
        input   => { %CLAUDE_INPUT, hook_event_name => 'SessionStart', source => 'startup' },
        env     => \%PANE,
        answer  => answers(0),
    );
    is(event_of($named, 'session start named in the input')->{event}, 'session_start',
        'session start named in the input: the status event is sent');
    is_deeply($named->{requests}, [], 'session start named in the input: no briefing request');

    # Perl run on its own keeps to the same rule.
    for my $hook (qw(SessionStart Stop)) {
        my $run = run_hook(
            command => ['perl', $HOOK_PL, 'claude', $hook],
            input   => { %CLAUDE_INPUT, hook_event_name => 'SessionStart' },
            env     => \%PANE,
            answer  => answers(0),
        );
        if ($hook eq 'SessionStart') {
            is(briefing_of($run, 'Perl on its own at a session start'), $BRIEFING,
                'Perl on its own at a session start: the briefing');
        }
        else {
            is($run->{stdout}, '', "Perl on its own for $hook with session start input: nothing on stdout");
            is_deeply($run->{requests}, [], "Perl on its own for $hook with session start input: no request");
        }
    }

    for my $args (['someone-else', 'SessionStart'], ['', 'SessionStart']) {
        my $run = run_hook(
            command => ['sh', "$PLUGIN{claude}/hooks/flashteams-hook.sh", @$args],
            input   => { %CLAUDE_INPUT, hook_event_name => 'SessionStart' },
            answer  => answers(0),
        );
        no_briefing($run, "starter for agent '$args->[0]'");
        is_deeply($run->{requests}, [], "starter for agent '$args->[0]': no request");
    }
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

        my $start = quiet("$name at a session start", command => ['sh', "$dir/flashteams-hook.sh", 'claude', 'SessionStart'],
            listener => $LISTENER);
        is($start->{data}, '', "$name at a session start: nothing sent");
    }
}

# At a session start the starter passes on only what looks like one whole
# briefing object, and only when the hook program finished well. A program
# that prints anything else, fails or is killed leaves the agent nothing.
{
    my $object = q({"hookSpecificOutput":{"additionalContext":"x","hookEventName":"SessionStart"}});
    my %programs = (
        'one briefing object'                 => [1, "print q($object), qq{\\n};\n"],
        'one briefing object, no newline'     => [1, "print q($object);\n"],
        'noise'                               => [0, "print qq{noise\\n};\n"],
        'noise before the object'             => [0, "print qq{noise }, q($object), qq{\\n};\n"],
        'two objects'                         => [0, "print q($object), qq{\\n}, q($object), qq{\\n};\n"],
        'half an object'                      => [0, "print substr(q($object), 0, 30);\n"],
        'an object, then a failure'           => [0, "print q($object), qq{\\n};\nexit 3;\n"],
        'an object, then death'               => [0, "print q($object), qq{\\n};\ndie qq{broke\\n};\n"],
        'an object, then killed'              => [0, "\$| = 1;\nprint q($object), qq{\\n};\nkill 'KILL', \$\$;\nsleep 5;\n"],
        'another hook\'s object'              => [0, "print q({\"decision\":\"block\"}), qq{\\n};\n"],
    );
    my $n = 0;
    for my $name (sort keys %programs) {
        my ($passes, $program) = @{ $programs{$name} };
        my $dir = "$TMP/printing-" . ++$n . '/hooks';
        make_path($dir);
        copy("$ROOT/shared/hooks/flashteams-hook.sh", "$dir/flashteams-hook.sh") or die $!;
        write_file("$dir/flashteams-hook.pl", $program);
        my $run = run_hook(command => ['sh', "$dir/flashteams-hook.sh", 'claude', 'SessionStart'], listener => undef);
        is($run->{status}, 0,  "a hook program printing $name: exits 0");
        is($run->{stderr}, '', "a hook program printing $name: nothing on stderr");
        is($run->{stdout}, $passes ? "$object\n" : '',
            $passes ? "a hook program printing $name: passed on" : "a hook program printing $name: nothing passed on");

        my $other = run_hook(command => ['sh', "$dir/flashteams-hook.sh", 'claude', 'Stop'], listener => undef);
        is($other->{stdout}, '', "a hook program printing $name for Stop: nothing passed on");
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
        my ($agent, $options, $root, $hook) = @_;
        my ($command, $root_env) = agent_command($agent, $hook // 'Stop', $root);
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

            # A session start prints the briefing and nothing else: no trace.
            my %start = $agent_shell->($agent, $options, undef, 'SessionStart');
            my $briefed = session_start(agent => $agent, command => $start{command},
                env => { PATH => $path, %{ $start{root_env} } });
            is(briefing_of($briefed, "$agent briefing with SHELLOPTS=$options"), $BRIEFING,
                "$agent briefing with SHELLOPTS=$options: the briefing");
            my $started = session_start(agent => $agent, command => ['sh', "$PLUGIN{$agent}/hooks/flashteams-hook.sh",
                $agent, 'SessionStart'], env => { %env });
            is(briefing_of($started, "$agent starter run directly for a briefing with SHELLOPTS=$options"), $BRIEFING,
                "$agent starter run directly for a briefing with SHELLOPTS=$options: the briefing");
            my %gone_start = $agent_shell->($agent, $options, "$TMP/deleted-plugin", 'SessionStart');
            no_briefing(session_start(agent => $agent, command => $gone_start{command},
                env => { PATH => $path, %{ $gone_start{root_env} } }),
                "$agent session start with a deleted plugin folder and SHELLOPTS=$options", 1.5);
        }
        no_briefing(run_hook(command => ['sh', "$failing/hooks/flashteams-hook.sh", 'claude', 'SessionStart'],
            env => \%env, input => { %CLAUDE_INPUT, hook_event_name => 'SessionStart' }, answer => answers(0)),
            "a failing hook program at a session start with SHELLOPTS=$options", 1.5);
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
