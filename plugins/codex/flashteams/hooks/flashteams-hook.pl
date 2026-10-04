#!/usr/bin/perl
# FlashTeams agent hook: tells Flash Console what a coding agent is doing,
# and at the start of a session asks Flash Console for the agent's
# FlashTeams briefing.
#
#   perl flashteams-hook.pl <agent> <hook-event>
#
# <agent> is claude or codex, and <hook-event> is the agent's own name for
# the hook that fired, such as Stop. The agent writes the hook's input, one
# JSON object, on stdin.
#
# The hook turns that input into one Flash Console agent event (protocol
# version 1, described in the README) and writes it as one line of JSON to
# Flash Console's private socket on this computer. At a session start it
# then sends one briefing request over the same socket and, when Flash
# Console answers in time, prints the briefing for the agent to read.
# Nothing is sent anywhere else.
#
# Rules this program keeps, whatever happens:
#   - only a session start named on the command line writes to stdout, and
#     then only one JSON object holding the briefing, after a good answer,
#     or a short note that the briefing could not be sent, after a refusal;
#     every other hook writes nothing to stdout, and none to the terminal;
#   - it never waits long: it gives up on a status event after 200 ms, on
#     the briefing after 1.5 seconds, and on the whole run after 1.8
#     seconds, or 3.3 at a session start;
#   - it always exits 0, even when Flash Console is not running;
#   - it reads at most 1 MB of input and never decodes a tool's whole input
#     or output, only the few fields it needs;
#   - it needs nothing but Perl and the modules that ship with it.

use 5.010;
use strict;
use warnings;
use feature 'unicode_strings';

use Encode ();
use IO::Select ();
use IO::Socket::UNIX ();
use JSON::PP ();
use Socket qw(SOCK_STREAM);
use Time::HiRes ();

our $VERSION = '1.1.0';

use constant {
    PROTOCOL_VERSION => 1,
    MAX_INPUT        => 1024 * 1024,    # bytes of hook input read
    MAX_LINE         => 8192,           # bytes of the line sent, newline included
    MAX_REQUEST      => 16384,          # bytes of a briefing request, newline included
    MAX_REPLY        => 1024 * 1024,    # bytes of Flash Console's answer, newline included
    CONTEXT_LIMIT    => 10000,          # UTF-16 units of briefing an agent takes in one piece
    EXCERPT_LIMIT    => 320,            # characters in an excerpt
    NAME_LIMIT       => 64,
    ID_LIMIT         => 128,
    PATH_LIMIT       => 1024,
    RAW_TEXT_LIMIT   => 16384,          # bytes of a long string decoded for an excerpt
    RAW_ID_LIMIT     => 8192,           # longer ids and paths are dropped unread
    STDIN_SECONDS    => 1.0,            # longest wait for the agent's input
    SOCKET_SECONDS   => 0.2,            # longest wait to connect and write
    BRIEFING_SECONDS => 1.5,            # longest wait for the briefing, connecting included
    DRAIN_SECONDS    => 0.3,            # longest time spent reading unused input
    RUN_SECONDS      => 1.8,            # hard limit on the whole run, before the briefing
};

my $STARTED = Time::HiRes::time();

# Text that must never reach Flash Console: control characters, line and
# paragraph separators, the invisible marks that reorder text on screen
# (U+061C, U+200E, U+200F, U+202A to U+202E, U+2066 to U+2069), and the
# other characters that take no space, so text can hide nothing between its
# visible letters (U+200B to U+200D, U+2060 to U+2064, U+FEFF).
my $UNSAFE = qr/[\p{Cc}\x{061C}\x{200B}-\x{200F}\x{2028}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}]/;

# What each JSON escape stands for.
my %ESCAPES = (q{"} => q{"}, q{\\} => q{\\}, q{/} => q{/}, b => "\b", f => "\f", n => "\n", r => "\r", t => "\t");

$SIG{PIPE} = 'IGNORE';

# Only a session start may answer the agent, on stdout, so only then is a
# copy of stdout kept for the answer. Everything else this program might
# print goes nowhere.
my $ANSWER;
if (($ARGV[1] // '') eq 'SessionStart') {
    open($ANSWER, '>&', \*STDOUT) or undef $ANSWER;
}
open(STDOUT, '>', '/dev/null');
open(STDERR, '>', '/dev/null');

my $briefing;
eval {
    local $SIG{ALRM} = sub { die "out of time\n" };
    Time::HiRes::alarm(RUN_SECONDS + ($ANSWER ? BRIEFING_SECONDS : 0));
    $briefing = run(@ARGV);
    Time::HiRes::alarm(0);
    1;
};
answer($briefing) if $ANSWER && defined $briefing;
exit 0;

sub run {
    my ($agent, $hook) = @_;
    $agent = lc($agent // '');
    return unless $agent eq 'claude' || $agent eq 'codex';

    my $socket = socket_path();
    return unless defined $socket && socket_is_ours($socket);

    my ($input, $at_end) = read_input();
    my $fields = scan_object(\$input, 0);
    my $in = Input->new(\$input, $fields);

    $hook = $in->text('hook_event_name', NAME_LIMIT) unless defined $hook && length $hook;
    return unless defined $hook;

    my $event = $agent eq 'claude' ? claude_event($hook, $in) : codex_event($hook, $in);
    if ($event) {
        my $line = build_line($agent, $event, $in);
        send_line($socket, $line) if defined $line;
    }

    # The status event goes first, so Flash Console hears of the session
    # however long the briefing takes.
    my $briefing;
    $briefing = ask_briefing($socket, $agent, $in) if $ANSWER && $hook eq 'SessionStart';

    drain_input() unless $at_end;
    return $briefing;
}

# Where Flash Console listens: FLASH_CONSOLE_AGENT_SOCKET when it is an
# absolute path, else the per-user default for this system.
sub socket_path {
    my $set = $ENV{FLASH_CONSOLE_AGENT_SOCKET};
    return $set if defined $set && $set =~ m{^/};
    if ($^O eq 'darwin') {
        my $home = $ENV{HOME};
        return undef unless defined $home && length $home;
        return "$home/Library/Application Support/Flash Console/agent.sock";
    }
    my $base = $ENV{XDG_RUNTIME_DIR};
    unless (defined $base && length $base) {
        my $home = $ENV{HOME};
        return undef unless defined $home && length $home;
        $base = "$home/.local/state";
    }
    return "$base/flash-console/agent.sock";
}

# Only a socket that belongs to the person running the agent gets events.
sub socket_is_ours {
    my ($path) = @_;
    my @st = lstat($path) or return 0;
    return -S _ && $st[4] == $>;
}

# The agent's input, at most MAX_INPUT bytes, and whether all of it was read.
sub read_input {
    my $data = '';
    my $at_end = 0;
    binmode(STDIN);
    my $select = IO::Select->new(\*STDIN);
    my $deadline = $STARTED + STDIN_SECONDS;
    while (length($data) < MAX_INPUT) {
        my $left = $deadline - Time::HiRes::time();
        last if $left <= 0;
        last unless $select->can_read($left);
        my $n = sysread(STDIN, $data, MAX_INPUT - length($data), length($data));
        if (!defined $n) {
            next if $!{EINTR} || $!{EAGAIN};
            last;
        }
        if ($n == 0) {
            $at_end = 1;
            last;
        }
    }
    return ($data, $at_end);
}

# Reads and drops the rest of a long input for a short while, so the agent
# can finish writing it without an error.
sub drain_input {
    my $select = IO::Select->new(\*STDIN);
    my $deadline = Time::HiRes::time() + DRAIN_SECONDS;
    my $buffer;
    while (1) {
        my $left = $deadline - Time::HiRes::time();
        last if $left <= 0;
        last unless $select->can_read($left);
        my $n = sysread(STDIN, $buffer, 65536);
        next if !defined $n && ($!{EINTR} || $!{EAGAIN});
        last unless $n;
    }
    return;
}

# ---------------------------------------------------------------------------
# Mapping each agent's hooks to protocol events. Each returns a hash of the
# event's own fields, or nothing when the hook is not one Flash Console needs.

sub claude_event {
    my ($hook, $in) = @_;

    if ($hook eq 'SessionStart') {
        return session_event($in);
    }
    if ($hook eq 'UserPromptSubmit') {
        return { event => 'prompt_submit', query => $in->excerpt('prompt') };
    }
    if ($hook eq 'PreToolUse') {
        # Registered only for the question tool, but checked again here.
        return unless ($in->text('tool_name', ID_LIMIT) // '') eq 'AskUserQuestion';
        return question_event($in);
    }
    if ($hook eq 'PostToolUse' || $hook eq 'PostToolUseFailure') {
        return tool_event('tool_complete', $in);
    }
    if ($hook eq 'PermissionRequest') {
        # Answering a question also passes through the permission check;
        # Flash Console hears about it as a question, once.
        return question_event($in)
          if ($in->text('tool_name', ID_LIMIT) // '') eq 'AskUserQuestion';
        my $event = tool_event('permission_request', $in);
        $event->{summary} = permission_summary($in);
        return $event;
    }
    if ($hook eq 'Notification') {
        my $type = $in->text('notification_type', NAME_LIMIT) // '';
        my %kind = (
            permission_prompt      => 'permission_request',
            idle_prompt            => 'idle_prompt',
            elicitation_dialog     => 'question_asked',
            elicitation_url_dialog => 'question_asked',
        );
        return unless $kind{$type};
        return { event => $kind{$type}, summary => $in->excerpt('message') };
    }
    if ($hook eq 'Stop') {
        # Sent even when stop_hook_active is true: this is still the real
        # end of the turn as far as the person is concerned.
        return { event => 'stop', response => $in->excerpt('last_assistant_message') };
    }
    if ($hook eq 'StopFailure') {
        return {
            event         => 'stop_failure',
            error_type    => $in->text('error', ID_LIMIT),
            error_message => $in->excerpt('last_assistant_message') // $in->excerpt('error_details'),
        };
    }
    return;
}

sub codex_event {
    my ($hook, $in) = @_;

    if ($hook eq 'SessionStart') {
        return session_event($in);
    }
    if ($hook eq 'UserPromptSubmit') {
        return { event => 'prompt_submit', query => $in->excerpt('prompt') };
    }
    if ($hook eq 'PreToolUse') {
        # Registered only for the tool that asks the person for input.
        return unless ($in->text('tool_name', ID_LIMIT) // '') eq 'request_user_input';
        return question_event($in);
    }
    if ($hook eq 'PostToolUse') {
        return tool_event('tool_complete', $in);
    }
    if ($hook eq 'PermissionRequest') {
        my $event = tool_event('permission_request', $in);
        $event->{summary} = permission_summary($in);
        return $event;
    }
    if ($hook eq 'Stop') {
        return { event => 'stop', response => $in->excerpt('last_assistant_message') };
    }
    if ($hook eq 'Interrupt') {
        return { event => 'stop', interrupted => JSON::PP::true };
    }
    return;
}

# Why the session started, in the agent's own word (such as startup, resume,
# clear or compact), passed on as given. Flash Console uses it to tell the
# same pane moving to a new conversation from another agent starting inside
# it.
sub session_event {
    my ($in) = @_;
    return { event => 'session_start', source => $in->text('source', NAME_LIMIT) };
}

sub tool_event {
    my ($name, $in) = @_;
    return {
        event      => $name,
        tool_name  => $in->text('tool_name', ID_LIMIT),
        tool_input => $in->raw_excerpt('tool_input'),
    };
}

# What a permission request is for, in the agent's own words when it gave
# some, else the command or file involved.
sub permission_summary {
    my ($in) = @_;
    my $tool = $in->object('tool_input') or return undef;
    for my $key (qw(description command file_path url)) {
        my $text = $tool->excerpt($key);
        return $text if defined $text;
    }
    return undef;
}

# The first question the agent asks, from either agent's question tool.
sub question_event {
    my ($in) = @_;
    my $summary;
    if (my $tool = $in->object('tool_input')) {
        if (my $first = $tool->first_object_in('questions')) {
            $summary = $first->excerpt('question');
        }
        $summary //= $tool->excerpt($_) for qw(question prompt message);
    }
    return { event => 'question_asked', summary => $summary };
}

# ---------------------------------------------------------------------------
# The line sent to Flash Console.

sub build_line {
    my ($agent, $event, $in) = @_;

    my $cwd = $in->text('cwd', PATH_LIMIT);
    my %line = (
        %$event,
        v              => PROTOCOL_VERSION,
        agent          => $agent,
        session_id     => $in->text('session_id', ID_LIMIT),
        cwd            => $cwd,
        project        => project_name($cwd),
        plugin_version => $VERSION,
    );

    # Claude Code runs its hooks inside its own process in the tab, so its
    # environment names the pane. Codex runs hooks in a shared background
    # server whose environment belongs to whichever terminal started it, so
    # a Codex event never names a pane.
    if ($agent eq 'claude') {
        $line{pane} = clean($ENV{FLASH_CONSOLE_PANE}, ID_LIMIT);
    }

    # Both agents name the subagent a hook fired in with agent_id, and leave
    # it out for the main agent. An id too long to send still marks the
    # event as a subagent's.
    if ($in->nonempty_string('agent_id')) {
        $line{subagent}    = JSON::PP::true;
        $line{subagent_id} = $in->text('agent_id', ID_LIMIT);
    }

    for my $key (keys %line) {
        delete $line{$key} unless defined $line{$key};
    }

    # Normally the line is well under the limit. When it is not, excerpts
    # get shorter, then go, then the project name, then the working folder,
    # and last everything but the essentials.
    my $json = JSON::PP->new->utf8->canonical;
    my @excerpts = grep { exists $line{$_} } qw(tool_input response query summary error_message);
    my @steps;
    for my $limit (160, 80, 40) {
        push @steps, sub {
            for my $key (@excerpts) {
                $_[0]{$key} = shorten($_[0]{$key}, $limit) if exists $_[0]{$key};
            }
        };
    }
    push @steps, sub { delete @{ $_[0] }{@excerpts} };
    push @steps, sub { delete $_[0]{project} };
    push @steps, sub { delete $_[0]{cwd} };
    push @steps, sub {
        my %keep = map { $_ => 1 }
          qw(v agent event session_id source pane subagent subagent_id interrupted plugin_version);
        delete @{ $_[0] }{ grep { !$keep{$_} } keys %{ $_[0] } };
    };

    my $text = $json->encode(\%line) . "\n";
    for my $step (@steps) {
        last if length($text) <= MAX_LINE;
        $step->(\%line);
        $text = $json->encode(\%line) . "\n";
    }
    return length($text) <= MAX_LINE ? $text : undef;
}

# The name of the project the agent works in: the folder that holds the git
# repository around the working folder, or else the working folder itself.
sub project_name {
    my ($cwd) = @_;
    return undef unless defined $cwd && $cwd =~ m{^/};
    # The file system takes bytes, so the walk works on the UTF-8 bytes.
    (my $dir = Encode::encode('UTF-8', $cwd)) =~ s{/+\z}{};
    my $probe = $dir;
    while (length $probe) {
        if (-e "$probe/.git") {
            $dir = $probe;
            last;
        }
        $probe =~ s{/[^/]*\z}{};
    }
    my ($name) = $dir =~ m{([^/]+)\z};
    return clean($name, PATH_LIMIT);
}

sub send_line {
    my ($path, $line) = @_;
    my $deadline = Time::HiRes::time() + SOCKET_SECONDS;
    my $sock = IO::Socket::UNIX->new(
        Type    => SOCK_STREAM,
        Peer    => $path,
        Timeout => SOCKET_SECONDS,
    ) or return;
    $sock->blocking(0);
    my $select = IO::Select->new($sock);
    my $sent = 0;
    while ($sent < length($line)) {
        my $left = $deadline - Time::HiRes::time();
        last if $left <= 0;
        my $n = syswrite($sock, $line, length($line) - $sent, $sent);
        if (defined $n) {
            $sent += $n;
            next;
        }
        last unless $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
        last unless $select->can_write($left);
    }
    close($sock);
    return;
}

# ---------------------------------------------------------------------------
# The start-up briefing.
#
# At a session start the hook asks Flash Console for the agent's briefing:
# how to reach FlashTeams through the flashteams command, whose sign-in it
# uses, the task chosen in Flash Console, and how FlashTeams expects agents
# to work. The request is one JSON line on the same socket, and Flash
# Console answers with one JSON line on the same connection. When Flash
# Console answers but refuses, for example because it is busy, the agent
# gets a short note instead: the command is there, and how to start with
# it. Any other trouble, such as no answer in time, an older Flash Console
# that closes without a word, or an answer that is not a good one, means no
# briefing and nothing printed.

sub ask_briefing {
    my ($path, $agent, $in) = @_;
    my $id = request_id();
    my %request = (
        v     => PROTOCOL_VERSION,
        op    => 'briefing',
        id    => $id,
        agent => $agent,
        cwd   => working_folder($in),
        # As with status events, only Claude Code's environment names the
        # pane the agent runs in.
        pane => $agent eq 'claude' ? (clean($ENV{FLASH_CONSOLE_PANE}, ID_LIMIT) // '') : '',
    );
    my $source = $in->text('source', NAME_LIMIT);
    $request{source} = $source if defined $source;

    my $line = JSON::PP->new->utf8->canonical->encode(\%request) . "\n";
    return undef if length($line) > MAX_REQUEST;
    my $reply = exchange($path, $line, BRIEFING_SECONDS);
    return undef unless defined $reply;
    return briefing_text($reply, $id);
}

# A fresh id for one request, 32 hex digits.
sub request_id {
    my $bytes = '';
    if (open(my $random, '<:raw', '/dev/urandom')) {
        read($random, $bytes, 16);
        close($random);
    }
    $bytes = pack('N4', map { int(rand(4294967296)) } 1 .. 4) unless length($bytes) == 16;
    return unpack('H*', $bytes);
}

# The agent's working folder, from its input, else this program's own.
sub working_folder {
    my ($in) = @_;
    my $cwd = $in->text('cwd', PATH_LIMIT);
    return $cwd if defined $cwd && $cwd =~ m{^/};
    require Cwd;
    $cwd = clean(Cwd::getcwd(), PATH_LIMIT);
    return defined $cwd && $cwd =~ m{^/} ? $cwd : '';
}

# Writes one request line and reads the one line that answers it, all
# within $seconds. Returns the answer without its newline, or undef. An
# answer cut short by the connection closing is returned as it is and
# fails to decode later.
sub exchange {
    my ($path, $line, $seconds) = @_;
    my $deadline = Time::HiRes::time() + $seconds;
    my $sock = IO::Socket::UNIX->new(
        Type    => SOCK_STREAM,
        Peer    => $path,
        Timeout => $seconds,
    ) or return undef;
    $sock->blocking(0);
    my $select = IO::Select->new($sock);

    my $sent = 0;
    while ($sent < length($line)) {
        my $left = $deadline - Time::HiRes::time();
        return undef if $left <= 0;
        my $n = syswrite($sock, $line, length($line) - $sent, $sent);
        if (defined $n) {
            $sent += $n;
            next;
        }
        return undef unless $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
        $select->can_write($left);
    }

    my $reply = '';
    while (1) {
        my $left = $deadline - Time::HiRes::time();
        return undef if $left <= 0;
        next unless $select->can_read($left);
        my $before = length($reply);
        my $n = sysread($sock, $reply, 65536, $before);
        if (!defined $n) {
            next if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
            return undef;
        }
        last if $n == 0;
        my $end = index($reply, "\n", $before);
        if ($end >= 0) {
            substr($reply, $end) = '';
            last;
        }
        return undef if length($reply) >= MAX_REPLY;
    }
    close($sock);
    return length($reply) && length($reply) < MAX_REPLY ? $reply : undef;
}

# What to tell the agent from Flash Console's answer to request $id, ready
# for the agent, or undef. An answer is a JSON object with v 1 and the
# request's id. With ok true and some text, that text is the briefing.
# With ok false, Flash Console is there but could not brief this session,
# and the agent hears that in a short note.
sub briefing_text {
    my ($reply, $id) = @_;
    my $answer = eval { JSON::PP->new->utf8->decode($reply) };
    return undef unless ref $answer eq 'HASH';
    my ($v, $answer_id, $ok, $text) = @{$answer}{qw(v id ok text)};
    return undef unless defined $v && !ref $v && $v eq PROTOCOL_VERSION;
    return undef unless is_string($answer_id) && $answer_id eq $id;
    return undef unless ref $ok eq 'JSON::PP::Boolean';
    return refusal_note($answer) unless $ok;
    return undef unless is_string($text);

    # Lines and tabs stay. Other line breaks become lines, other control
    # characters become a space, so the words around them stay apart, and
    # the invisible characters go, as from any other text the hook passes
    # on.
    $text =~ s/\r\n?/\n/g;
    $text =~ s/[\x0B\x0C\x{85}\x{2028}\x{2029}]/\n/g;
    $text =~ s/[^\P{Cc}\n\t]+/ /g;
    $text =~ s/(?![\n\t])$UNSAFE//g;
    return undef unless $text =~ /\S/;
    return fit_context($text);
}

# The note for a refusal: that the briefing could not be sent, why, in
# Flash Console's own words when it gave some, and how to start with the
# command anyway. Flash Console refuses a briefing only when something is
# wrong for now, such as too many requests at once; when FlashTeams for
# agents is off or nobody is signed in it says so with ok true.
sub refusal_note {
    my ($answer) = @_;
    my ($code, $message) = @{$answer}{qw(code message)};
    my $why = is_string($message) ? excerpt_of($message) : undef;
    $why //= "Its answer was $code." if is_string($code) && $code =~ /\A[a-z_]{1,32}\z/;
    return "Flash Console could not send the FlashTeams briefing for this session."
      . (defined $why ? " $why" : '')
      . "\nThe flashteams command may still work: run flashteams tools for the list of tools"
      . " and flashteams help <tool> for a tool's arguments.";
}

# Whether a decoded JSON value was a string, not a number, true, false,
# null, an array or an object. A number decodes to a Perl number, which
# never carries text alone.
sub is_string {
    my ($value) = @_;
    return 0 unless defined $value && !ref $value;
    require B;
    my $flags = B::svref_2object(\$value)->FLAGS;
    return 0 if $flags & (B::SVp_IOK() | B::SVp_NOK());
    return $flags & B::SVp_POK() ? 1 : 0;
}

# Agents take at most CONTEXT_LIMIT characters of start-up context in one
# piece, counted the way JavaScript counts a string's length: in UTF-16
# units, so a character past U+FFFF, such as most emoji, counts as two.
# Flash Console keeps its briefing well under that, but a longer one is cut
# at the end of a line and says how much was left out.
sub fit_context {
    my ($text) = @_;
    return $text if utf16_length($text) <= CONTEXT_LIMIT;
    my $room = CONTEXT_LIMIT - 64;
    my $keep = substr($text, 0, $room);
    # Each character past U+FFFF in what is kept takes a second unit, so
    # characters come off the end until it fits.
    my $units = utf16_length($keep);
    while ($units > $room) {
        $units -= ord(chop $keep) > 0xFFFF ? 2 : 1;
    }
    $keep =~ s/(?<=\n)[^\n]+\z//;
    my $more = length($text) - length($keep);
    $keep .= "\n" unless $keep =~ /\n\z/;
    return $keep . "[cut: $more more characters]";
}

# How long JavaScript, and so the agent, takes a text to be.
sub utf16_length {
    my ($text) = @_;
    return length($text) + ($text =~ tr/\x{10000}-\x{10FFFF}//);
}

# Prints the briefing as the one JSON object both agents read from a
# session start hook's stdout.
sub answer {
    my ($text) = @_;
    eval {
        my $json = JSON::PP->new->utf8->canonical->encode(
            { hookSpecificOutput => { hookEventName => 'SessionStart', additionalContext => $text } });
        binmode($ANSWER);
        print {$ANSWER} $json, "\n";
        close($ANSWER);
        1;
    };
    return;
}

# ---------------------------------------------------------------------------
# Text cleaning.

# Ids, names and paths: no unsafe characters, and too long means unusable.
sub clean {
    my ($text, $limit) = @_;
    return undef unless defined $text;
    $text = Encode::decode('UTF-8', $text) unless utf8::is_utf8($text);
    $text =~ s/$UNSAFE//g;
    $text =~ s/\A\s+|\s+\z//g;
    return undef if $text eq '' || length($text) > $limit;
    return $text;
}

# Prompts, replies, summaries and tool input: one line of single spaces, no
# unsafe characters, at most EXCERPT_LIMIT characters.
sub excerpt_of {
    my ($text) = @_;
    return undef unless defined $text;
    $text =~ s/\s+/ /g;
    $text =~ s/$UNSAFE//g;
    $text =~ s/ {2,}/ /g;
    $text =~ s/\A | \z//g;
    return undef if $text eq '';
    return shorten($text, EXCERPT_LIMIT);
}

sub shorten {
    my ($text, $limit) = @_;
    return $text if length($text) <= $limit;
    $text = substr($text, 0, $limit - 1);
    $text =~ s/ \z//;
    return $text . "\x{2026}";
}

# ---------------------------------------------------------------------------
# Reading only what is needed from the input.
#
# The input can be large: a tool's whole output, a pasted file. Rather than
# decode all of it, scan_object walks one JSON object's members and notes
# where each value starts and ends, skipping over the values themselves.
# Only the few values the event needs are then decoded, and long strings
# only as far as an excerpt needs. A value cut off by the input limit is
# noted as partial and is still good for an excerpt.
#
# Readers that return one value return undef, never an empty list, when
# there is nothing to read, so they are safe to call inside a hash list.

sub scan_object {
    my ($ref, $start) = @_;
    my %members;
    pos($$ref) = $start;
    return \%members unless $$ref =~ /\G\s*\{/gc;
    while (1) {
        $$ref =~ /\G\s*/gc;
        my $key_start = pos($$ref);
        last unless substr($$ref, $key_start, 1) eq '"';
        my $key_end = string_end($ref, $key_start) // last;
        pos($$ref) = $key_end;
        last unless $$ref =~ /\G\s*:\s*/gc;
        my $value_start = pos($$ref);
        my $key_length = $key_end - $key_start - 2;
        my $key = $key_length <= 256 ? decode_string(substr($$ref, $key_start + 1, $key_length)) : undef;
        my $value_end = value_end($ref, $value_start);
        if (!defined $value_end) {
            $members{$key} //= [$value_start, length($$ref), 1] if defined $key;
            last;
        }
        $members{$key} //= [$value_start, $value_end, 0] if defined $key;
        pos($$ref) = $value_end;
        last unless $$ref =~ /\G\s*,/gc;
    }
    return \%members;
}

# Where the JSON value starting at $start ends, or undef when the input ends
# first.
sub value_end {
    my ($ref, $start) = @_;
    my $first = substr($$ref, $start, 1);
    return string_end($ref, $start) if $first eq '"';
    if ($first eq '{' || $first eq '[') {
        my $depth = 0;
        pos($$ref) = $start;
        while ($$ref =~ /\G[^"{}\[\]]*+([\[\]{}"])/gc) {
            my $mark = $1;
            if ($mark eq '"') {
                my $end = string_end($ref, pos($$ref) - 1) // return undef;
                pos($$ref) = $end;
            }
            elsif ($mark eq '{' || $mark eq '[') {
                $depth++;
            }
            else {
                $depth--;
                return pos($$ref) if $depth == 0;
            }
        }
        return undef;
    }
    pos($$ref) = $start;
    return $$ref =~ /\G[^,}\]\s]+/gc ? pos($$ref) : undef;
}

# Where the JSON string whose opening quote is at $start ends, just past its
# closing quote, or undef when the input ends first.
sub string_end {
    my ($ref, $start) = @_;
    my $at = $start + 1;
    while (1) {
        my $quote = index($$ref, '"', $at);
        return undef if $quote < 0;
        my $slashes = 0;
        my $back = $quote - 1;
        while ($back > $start && substr($$ref, $back, 1) eq '\\') {
            $slashes++;
            $back--;
        }
        return $quote + 1 unless $slashes % 2;
        $at = $quote + 1;
    }
}

# The text of a JSON string's contents, given as raw bytes without quotes.
sub decode_string {
    my ($raw) = @_;
    my $text = Encode::decode('UTF-8', $raw);
    $text =~ s{\\(?:u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|(.))}{
        defined $1 ? chr(0x10000 + ((hex($1) - 0xD800) << 10) + (hex($2) - 0xDC00))
      : defined $3 ? surrogate_safe(hex($3))
      : exists $ESCAPES{$4} ? $ESCAPES{$4}
      : $4
    }gse;
    return $text;
}

sub surrogate_safe {
    my ($code) = @_;
    return $code >= 0xD800 && $code <= 0xDFFF ? "\x{FFFD}" : chr($code);
}

package Input;

# One JSON object in the input, read lazily.

sub new {
    my ($class, $ref, $members) = @_;
    return bless { ref => $ref, members => $members }, $class;
}

# The raw bytes of a member's value, at most $limit of them, and whether the
# value is longer than that.
sub raw {
    my ($self, $key, $limit) = @_;
    my $span = $self->{members}{$key} or return;
    my ($start, $end, $partial) = @$span;
    my $length = $end - $start;
    my $cut = $partial || $length > $limit;
    $length = $limit if $length > $limit;
    return (substr(${ $self->{ref} }, $start, $length), $cut);
}

# A string member's text, at most $limit characters, else nothing.
sub text {
    my ($self, $key, $limit) = @_;
    my ($raw, $cut) = $self->raw($key, main::RAW_ID_LIMIT()) or return undef;
    return undef if $cut || $raw !~ /\A"(.*)"\z/s;
    return main::clean(main::decode_string($1), $limit);
}

# Whether a member is a string with something in it, however long.
sub nonempty_string {
    my ($self, $key) = @_;
    my $span = $self->{members}{$key} or return 0;
    return substr(${ $self->{ref} }, $span->[0], 2) =~ /\A"[^"]/ ? 1 : 0;
}

# A string member as an excerpt.
sub excerpt {
    my ($self, $key) = @_;
    my ($raw) = $self->raw($key, main::RAW_TEXT_LIMIT()) or return undef;
    return undef unless $raw =~ s/\A"//;
    $raw =~ s/"\z//;
    return main::excerpt_of(main::decode_string($raw));
}

# Any member as an excerpt of its JSON text, as the agent wrote it.
sub raw_excerpt {
    my ($self, $key) = @_;
    my ($raw) = $self->raw($key, main::RAW_TEXT_LIMIT()) or return undef;
    return undef if $raw eq 'null';
    return main::excerpt_of(Encode::decode('UTF-8', $raw));
}

# An object member, to read further members from.
sub object {
    my ($self, $key) = @_;
    my $span = $self->{members}{$key} or return undef;
    my $ref = $self->{ref};
    return undef unless substr($$ref, $span->[0], 1) eq '{';
    return Input->new($ref, main::scan_object($ref, $span->[0]));
}

# The first element of an array member, when it is an object.
sub first_object_in {
    my ($self, $key) = @_;
    my $span = $self->{members}{$key} or return undef;
    my $ref = $self->{ref};
    pos($$ref) = $span->[0];
    return undef unless $$ref =~ /\G\[\s*/gc;
    my $at = pos($$ref);
    return undef unless substr($$ref, $at, 1) eq '{';
    return Input->new($ref, main::scan_object($ref, $at));
}
