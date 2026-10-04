#!/usr/bin/perl
# Checks the marketplaces, plugin manifests, MCP servers, hooks
# configuration, skills and the Claude Code shim of every plugin against
# each other and against the hook.
#
# Each agent has two plugins. flashteams holds the status hooks, the
# start-up briefing, the flashteams skill and, for Claude Code, the shim
# that puts the flashteams command on the Bash tool's PATH. flashteams-mcp
# holds only the MCP server and the skill that uses it, so a person can
# install flashteams alone.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Find qw(find);
use FindBin;
use JSON::PP;
use Test::More;

my $ROOT = abs_path("$FindBin::Bin/..");
my %PLUGINS = (
    claude => { flashteams => 'plugins/claude/flashteams', 'flashteams-mcp' => 'plugins/claude/flashteams-mcp' },
    codex  => { flashteams => 'plugins/codex/flashteams',  'flashteams-mcp' => 'plugins/codex/flashteams-mcp' },
);
my $CLAUDE     = $PLUGINS{claude}{flashteams};
my $CLAUDE_MCP = $PLUGINS{claude}{'flashteams-mcp'};
my $CODEX      = $PLUGINS{codex}{flashteams};
my $CODEX_MCP  = $PLUGINS{codex}{'flashteams-mcp'};
my $RELEASE = '1.1.0';
my $MCP_URL = 'https://flashteams-mcp-server.nisitha.workers.dev/mcp';
my $MCP_SERVER = { mcpServers => { flashteams => { type => 'http', url => $MCP_URL } } };

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', "$ROOT/$path") or die "$path: $!";
    local $/;
    return scalar <$fh>;
}

sub json {
    my ($path) = @_;
    my $data = eval { decode_json(slurp($path)) };
    ok($data, "$path is valid JSON") or diag($@);
    return $data || {};
}

# Every file under a folder, relative to it.
sub files_in {
    my ($dir) = @_;
    my @files;
    find(
        {
            no_chdir => 1,
            wanted   => sub { push @files, substr($_, length("$ROOT/$dir") + 1) if -f $_ },
        },
        "$ROOT/$dir"
    );
    return sort @files;
}

my ($hook_version) = slurp('shared/hooks/flashteams-hook.pl') =~ /^our \$VERSION = '([^']+)';/m;
is($hook_version, $RELEASE, "the hook is version $RELEASE");

# ---------------------------------------------------------------------------
# Claude Code marketplace and plugins.

{
    my $market = json('.claude-plugin/marketplace.json');
    is($market->{name}, 'flashteams', 'Claude Code marketplace is named flashteams');
    ok($market->{owner} && $market->{owner}{name}, 'Claude Code marketplace has an owner');
    my @entries = @{ $market->{plugins} || [] };
    is_deeply([map { $_->{name} } @entries], [qw(flashteams flashteams-mcp)],
        'Claude Code marketplace lists flashteams and flashteams-mcp');
    for my $entry (@entries) {
        my $name = $entry->{name};
        is($entry->{source}, "./$PLUGINS{claude}{$name}", "Claude Code $name entry points at its own folder");
        ok(!exists $entry->{version}, "Claude Code $name: the version lives only in plugin.json");
        ok($entry->{description}, "Claude Code $name entry has a description");

        my $manifest = json("$PLUGINS{claude}{$name}/.claude-plugin/plugin.json");
        is($manifest->{name},    $name,         "Claude Code $name plugin.json name");
        is($manifest->{version}, $hook_version, "Claude Code $name plugin version matches the hook");
        is($manifest->{license}, 'MIT',         "Claude Code $name plugin license");
        ok(!exists $manifest->{$_}, "Claude Code $name plugin.json names no $_, so the default folders hold them")
          for qw(hooks mcpServers skills);
    }

    # flashteams: hooks, the skill and the shim, and no MCP server.
    is_deeply(
        [files_in($CLAUDE)],
        [qw(.claude-plugin/plugin.json bin/flashteams hooks/flashteams-hook.pl hooks/flashteams-hook.sh
            hooks/hooks.json skills/flashteams/SKILL.md)],
        'the Claude Code flashteams plugin holds the hooks, the flashteams skill and the shim'
    );
    ok(-x "$ROOT/$CLAUDE/bin/flashteams", 'the Claude Code shim is executable');
    like(slurp("$CLAUDE/bin/flashteams"), qr{\A#!/bin/sh\n}, 'the Claude Code shim is a POSIX sh script');

    # flashteams-mcp: the MCP server and its skill, nothing else.
    is_deeply(
        [files_in($CLAUDE_MCP)],
        [qw(.claude-plugin/plugin.json .mcp.json skills/flashteams-next-task/SKILL.md)],
        'the Claude Code flashteams-mcp plugin holds only the MCP server and its skill'
    );
    is_deeply(json("$CLAUDE_MCP/.mcp.json"), $MCP_SERVER,
        'Claude Code flashteams-mcp bundles the flashteams MCP server, with no token or header');
}

# ---------------------------------------------------------------------------
# Codex marketplace and plugins.
#
# Codex 0.160 loads a plugin's hooks only from a .codex-plugin/plugin.json
# manifest. Given a root plugin.json instead (the Agent Plugins layout), it
# still loads the skill and the MCP server but registers no hooks at all,
# even when a .codex-plugin/plugin.json sits beside it. So each Codex plugin
# has only .codex-plugin/plugin.json, and the hooks sit at hooks/hooks.json,
# where Codex looks when the manifest names no hooks.

{
    my $market = json('.agents/plugins/marketplace.json');
    is($market->{name}, 'flashteams', 'Codex marketplace is named flashteams');
    my @entries = @{ $market->{plugins} || [] };
    is_deeply([map { $_->{name} } @entries], [qw(flashteams flashteams-mcp)],
        'Codex marketplace lists flashteams and flashteams-mcp');
    my %installation = map { $_ => 1 } qw(NOT_AVAILABLE AVAILABLE INSTALLED_BY_DEFAULT);
    my %authentication = map { $_ => 1 } qw(ON_INSTALL ON_USE);
    for my $entry (@entries) {
        my $name = $entry->{name};
        is_deeply($entry->{source}, { source => 'local', path => "./$PLUGINS{codex}{$name}" },
            "Codex $name entry points at its own folder");
        ok(!exists $entry->{version}, "Codex $name: the version lives only in plugin.json");
        ok($installation{ $entry->{policy}{installation} // '' }, "Codex $name entry has an installation policy");
        ok($authentication{ $entry->{policy}{authentication} // '' }, "Codex $name entry has an authentication policy");
        ok($entry->{category}, "Codex $name entry has a category");

        my $manifest = json("$PLUGINS{codex}{$name}/.codex-plugin/plugin.json");
        is($manifest->{name},    $name,         "Codex $name plugin.json name");
        is($manifest->{version}, $hook_version, "Codex $name plugin version matches the hook");
        is($manifest->{license}, 'MIT',         "Codex $name plugin license");
        ok($manifest->{description} && $manifest->{author} && $manifest->{author}{name},
            "Codex $name plugin.json has a description and an author");
        is($manifest->{skills}, './skills/', "Codex $name plugin.json names the skills folder");

        # The fields Codex's own plugin validator accepts. It rejects hooks,
        # and naming hooks would also stop Codex looking at hooks/hooks.json.
        my %known = map { $_ => 1 } qw(id name version description skills apps mcpServers interface author
                                       homepage repository license keywords);
        my @unknown = grep { !$known{$_} } sort keys %$manifest;
        is("@unknown", '', "Codex $name plugin.json has only fields Codex accepts");
        ok(!exists $manifest->{hooks}, "Codex $name: hooks, if any, are found at hooks/hooks.json, the default");

        my $interface = $manifest->{interface} || {};
        for my $field (qw(displayName shortDescription longDescription developerName category)) {
            ok(defined $interface->{$field} && !ref $interface->{$field} && $interface->{$field} =~ /\S/,
                "Codex $name plugin interface has $field");
        }
        ok(ref $interface->{capabilities} eq 'ARRAY' && !grep({ ref $_ || !/\S/ } @{ $interface->{capabilities} }),
            "Codex $name plugin interface lists its capabilities");
        ok(ref $interface->{defaultPrompt} eq 'ARRAY' && @{ $interface->{defaultPrompt} } >= 1
              && @{ $interface->{defaultPrompt} } <= 3, "Codex $name plugin interface has one to three starter prompts");
        like($interface->{websiteURL} // '', qr{\Ahttps://}, "Codex $name plugin website is https");
    }

    ok(!exists json("$CODEX/.codex-plugin/plugin.json")->{mcpServers}, 'Codex flashteams has no MCP server');
    is(json("$CODEX_MCP/.codex-plugin/plugin.json")->{mcpServers}, './.mcp.json',
        'Codex flashteams-mcp plugin.json names its MCP servers file');

    # Codex puts no plugin folder on the PATH, so the Codex plugin has no
    # shim: Flash Console puts the flashteams command on the PATH itself.
    is_deeply(
        [files_in($CODEX)],
        [qw(.codex-plugin/plugin.json hooks/flashteams-hook.pl hooks/flashteams-hook.sh hooks/hooks.json
            skills/flashteams/SKILL.md)],
        'the Codex flashteams plugin holds the hooks and the flashteams skill'
    );
    is_deeply(
        [files_in($CODEX_MCP)],
        [qw(.codex-plugin/plugin.json .mcp.json skills/flashteams-next-task/SKILL.md)],
        'the Codex flashteams-mcp plugin holds only the MCP server and its skill'
    );
    is_deeply(json("$CODEX_MCP/.mcp.json"), $MCP_SERVER,
        'Codex flashteams-mcp bundles the flashteams MCP server, with no token or header');
}

# Neither agent can load the other's manifest. A Codex plugin has no root
# plugin.json, which would make Codex skip its hooks, and no mcp.json, which
# Codex would not read from this layout.
for my $name (qw(flashteams flashteams-mcp)) {
    ok(!-e "$ROOT/$PLUGINS{claude}{$name}/$_", "the Claude Code $name plugin has no $_")
      for qw(plugin.json mcp.json .codex-plugin);
    ok(!-e "$ROOT/$PLUGINS{codex}{$name}/$_", "the Codex $name plugin has no $_")
      for qw(.claude-plugin plugin.json mcp.json);
}

# ---------------------------------------------------------------------------
# Hooks: every command starts the shared hook with the right agent and the
# event it is registered for, through a guard that exits 0 without a word
# when the starter is missing or unreadable. Codex keeps running the hook
# commands it read from a plugin folder after an update has deleted that
# folder, and sh on a missing file complains and exits non-zero. Only two
# commands keep stdout: the session start, for the briefing, and Claude
# Code's permission check on Bash commands (flashteams-permission), for
# the answer that lets a plain flashteams command run without Claude Code's
# prompt. Every other hook discards stdout as well as stderr.

my $GUARD_START = q{sh -c '{ set +eux; } 2>/dev/null; f=$1; shift; [ -r "$f" ] || exit 0; };
my $QUIET_GUARD = $GUARD_START . q{sh "$f" "$@" >/dev/null 2>&1; exit 0' sh};
my $STDOUT_GUARD = $GUARD_START . q{sh "$f" "$@" 2>/dev/null; exit 0' sh};
my $PERMISSION = 'flashteams-permission';

# Each event's matcher groups, in order: the matcher, the name the command
# hands the starter, and whether the command keeps stdout.
my %HOOKS = (
    claude => {
        file   => "$CLAUDE/hooks/hooks.json",
        root   => 'CLAUDE_PLUGIN_ROOT',
        events => {
            SessionStart       => [[undef, 'SessionStart', 1]],
            UserPromptSubmit   => [[undef, 'UserPromptSubmit']],
            PreToolUse         => [['AskUserQuestion', 'PreToolUse'], ['Bash', $PERMISSION, 1]],
            PostToolUse        => [[undef, 'PostToolUse']],
            PostToolUseFailure => [[undef, 'PostToolUseFailure']],
            PermissionRequest  => [[undef, 'PermissionRequest']],
            Notification => [['permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog', 'Notification']],
            Stop               => [[undef, 'Stop']],
            StopFailure        => [[undef, 'StopFailure']],
        },
    },
    codex => {
        file   => "$CODEX/hooks/hooks.json",
        root   => 'PLUGIN_ROOT',
        events => {
            SessionStart      => [[undef, 'SessionStart', 1]],
            UserPromptSubmit  => [[undef, 'UserPromptSubmit']],
            PreToolUse        => [['^request_user_input$', 'PreToolUse']],
            PostToolUse       => [[undef, 'PostToolUse']],
            PermissionRequest => [[undef, 'PermissionRequest']],
            Stop              => [[undef, 'Stop']],
            Interrupt         => [[undef, 'Interrupt']],
        },
    },
);
for my $agent (sort keys %HOOKS) {
    my $spec = $HOOKS{$agent};
    my $config = json($spec->{file});
    is_deeply([sort keys %{ $config->{hooks} || {} }], [sort keys %{ $spec->{events} }], "$agent hooks the expected events");
    for my $event (sort keys %{ $config->{hooks} || {} }) {
        my $groups = $config->{hooks}{$event};
        my $expected = $spec->{events}{$event} || [];
        is(scalar @$groups, scalar @$expected, "$agent $event has " . scalar(@$expected) . ' matcher group(s)');
        for my $i (0 .. $#$expected) {
            my ($matcher, $name, $keeps_stdout) = @{ $expected->[$i] };
            my $group = $groups->[$i] || {};
            is($group->{matcher}, $matcher, "$agent $event matcher " . ($matcher // '(none)'));
            my @handlers = @{ $group->{hooks} || [] };
            is(scalar @handlers, 1, "$agent $event $name has one handler");
            my $handler = $handlers[0] || {};
            is($handler->{type}, 'command', "$agent $event $name is a command hook");
            my $guard = $keeps_stdout ? $STDOUT_GUARD : $QUIET_GUARD;
            is($handler->{command}, qq{$guard "\${$spec->{root}}/hooks/flashteams-hook.sh" $agent $name},
                $keeps_stdout
                ? "$agent $event $name starts the shared hook through the guard, keeping stdout for its answer"
                : "$agent $event $name starts the shared hook through the guard, with stdout discarded");
            ok(!exists $handler->{args}, "$agent $event $name runs through sh, so a missing Perl or starter stays quiet");
            ok(!$handler->{async}, "$agent $event $name runs in order");
            cmp_ok($handler->{timeout} // 99, '<=', 5, "$agent $event $name has a short timeout");
        }
    }
    # The hook's longest run at a session start: the input, the status
    # event and the briefing, well inside the agent's timeout.
    cmp_ok($config->{hooks}{SessionStart}[0]{hooks}[0]{timeout}, '>=', 4,
        "$agent SessionStart leaves time for the briefing");

    # Which commands keep stdout, read from the file itself.
    my @handlers = map { @{ $_->{hooks} } } map { @{ $config->{hooks}{$_} } } sort keys %{ $config->{hooks} || {} };
    my @keeping = sort map { $_->{command} =~ / (\S+)\z/ ? $1 : '?' }
      grep { $_->{command} !~ m{>/dev/null 2>&1; exit 0'} } @handlers;
    is_deeply(\@keeping, $agent eq 'claude' ? ['SessionStart', $PERMISSION] : ['SessionStart'],
        $agent eq 'claude'
        ? 'claude: only the session start and the permission check keep stdout'
        : 'codex: only the session start keeps stdout');
}

# Claude Code's permission check: a PreToolUse hook on the Bash tool, so it
# runs before every Bash command, and the flashteams skill's allowed-tools
# covers only the turn that loads the skill. Codex has no such hook: its
# approvals are about its sandbox, and Codex is left to ask as it does.
{
    my $claude = json("$CLAUDE/hooks/hooks.json")->{hooks};
    my ($bash) = grep { ($_->{matcher} // '') eq 'Bash' } @{ $claude->{PreToolUse} || [] };
    ok($bash, 'Claude Code has a PreToolUse hook on the Bash tool');
    like($bash && $bash->{hooks}[0]{command}, qr/ claude \Q$PERMISSION\E\z/, 'it runs the permission check');
    my @elsewhere = grep { $_ ne 'PreToolUse' && grep { $_->{command} =~ /\Q$PERMISSION\E/ } map { @{ $_->{hooks} } } @{ $claude->{$_} } }
      sort keys %$claude;
    is("@elsewhere", '', 'Claude Code runs the permission check for no other event');

    my $codex = json("$CODEX/hooks/hooks.json")->{hooks};
    my @codex_bash = grep { ($_->{matcher} // '') =~ /Bash/i } map { @{ $codex->{$_} } } sort keys %$codex;
    is(scalar @codex_bash, 0, 'Codex has no hook on Bash commands');
    my @codex_permission = grep { $_->{command} =~ /\Q$PERMISSION\E/ } map { @{ $_->{hooks} } } map { @{ $codex->{$_} } }
      sort keys %$codex;
    is(scalar @codex_permission, 0, 'Codex has no permission check');
}

# ---------------------------------------------------------------------------
# The copies in each plugin match shared/.

for my $plugin ($CLAUDE, $CODEX) {
    for my $file (qw(hooks/flashteams-hook.pl hooks/flashteams-hook.sh)) {
        (my $shared = $file) =~ s{^}{shared/};
        is(slurp("$plugin/$file"), slurp($shared), "$plugin/$file matches $shared (run script/sync)");
    }
}
is(slurp("$CLAUDE/bin/flashteams"), slurp('shared/bin/flashteams'),
    "$CLAUDE/bin/flashteams matches shared/bin/flashteams (run script/sync)");
for my $plugin ($CLAUDE_MCP, $CODEX_MCP) {
    my $skill = 'skills/flashteams-next-task/SKILL.md';
    is(slurp("$plugin/$skill"), slurp("shared/$skill"), "$plugin/$skill matches shared/$skill (run script/sync)");
}

# The flashteams skill: Codex's copy is shared/ as it is, and Claude Code's
# adds one frontmatter line, allowed-tools: Bash(flashteams:*), so the turn
# that loads the skill runs every flashteams command without Claude Code
# asking. Flash Console itself asks the person before the actions that
# need it. Claude Code drops that grant at the person's next message; from
# then on the permission check above lets a plain flashteams command run.
{
    my $skill = 'skills/flashteams/SKILL.md';
    my $shared = slurp("shared/$skill");
    is(slurp("$CODEX/$skill"), $shared, "$CODEX/$skill matches shared/$skill (run script/sync)");
    unlike($shared, qr/allowed-tools/, 'the Codex skill has no Claude Code field');

    my $copy = slurp("$CLAUDE/$skill");
    my ($line) = $copy =~ /\A---\n(?:[^\n]+\n)*?allowed-tools: ([^\n]*)\n(?:[^\n]+\n)*?---\n/;
    ok(defined $line, 'the Claude Code skill has allowed-tools in its frontmatter');
    (my $claude = $shared) =~ s/\A(---\n.*?\n)(---\n)/$1allowed-tools: @{[ $line \/\/ '' ]}\n$2/s;
    is($copy, $claude, "$CLAUDE/$skill is shared/$skill with allowed-tools added (run script/sync)");
    is($line, 'Bash(flashteams:*)', 'the Claude Code skill runs every flashteams command without asking');

    # The permission check that does the same after the skill's turn.
    my ($bash) = grep { ($_->{matcher} // '') eq 'Bash' } @{ json("$CLAUDE/hooks/hooks.json")->{hooks}{PreToolUse} || [] };
    like($bash && $bash->{hooks}[0]{command}, qr/ claude \Q$PERMISSION\E\z/,
        'beside it, the permission check covers every later turn');
}

# ---------------------------------------------------------------------------
# The skills name themselves and say when to use them.

{
    my $skill = slurp('shared/skills/flashteams-next-task/SKILL.md');
    like($skill, qr/\A---\nname: flashteams-next-task\ndescription: \S[^\n]+\n---\n/,
        'the next task skill has its frontmatter');
    like($skill, qr/find_tasks/,   'the next task skill finds the task');
    like($skill, qr/load_task/,    'the next task skill loads the briefing');
    like($skill, qr/`start`/,      'the next task skill starts the task before working');
    like($skill, qr/actual_hours/, 'the next task skill says how to log time');
}

{
    my $skill = slurp('shared/skills/flashteams/SKILL.md');
    my ($description) = $skill =~ /\A---\nname: flashteams\ndescription: (\S[^\n]+)\n---\n/;
    ok($description, 'the flashteams skill has its frontmatter');
    cmp_ok(length($description // ''), '<=', 1024, 'the flashteams skill description fits both agents');
    for my $topic ('projects', 'tasks', 'phases', 'programs', 'exploration graph', 'FlashBrain', 'recipes',
        'code graph')
    {
        like($description // '', qr/\Q$topic\E/, "the flashteams skill is for $topic");
    }
    like($skill, qr/flashteams tools/,               'the flashteams skill lists the tools');
    like($skill, qr/flashteams help/,                'the flashteams skill shows a tool\'s arguments');
    like($skill, qr/connect_workspace/,              'the flashteams skill connects the project');
    like($skill, qr/load_task/,                      'the flashteams skill loads the task');
    like($skill, qr/--action start/,                 'the flashteams skill starts the task before working');
    like($skill, qr/submit_for_review/,              'the flashteams skill submits for review');
    like($skill, qr/--action close/,                 'the flashteams skill closes with a handoff');
    like($skill, qr/plain\s+language/,               'the flashteams skill asks for a plain-language handoff');
    like($skill, qr/`-`/,                            'the flashteams skill passes long text through stdin');
    like($skill, qr/<<'EOF'/,                        'the flashteams skill shows a quoted here-document');
    like($skill, qr/Never invent hours/,             'the flashteams skill says never to invent hours');
    like($skill, qr/actual_hours/,                   'the flashteams skill says how to log time');
    like($skill, qr/sandbox/i,                       'the flashteams skill explains the sandbox');
    like($skill, qr/allowUnixSockets/,               'the flashteams skill names Claude Code\'s socket setting');
    like($skill, qr/^\| $_ \|/m, "the flashteams skill explains exit code $_") for 0 .. 5;

    # A tool's refusal exits 1 with its answer on stdout; exit 3 tries the
    # briefing's path once; after exit 5 a change is checked before it is
    # repeated, and FlashBrain is never asked twice.
    like($skill, qr/^\| 1 \|[^\n]*said no/m,             'exit 1: the tool or FlashTeams said no');
    like($skill, qr/prints the tool's answer as written on stdout/, 'a refusal is the tool\'s answer on stdout');
    unlike($skill, qr/still\s+exits 0/,                 'no refusal is described as exit 0');
    like($skill, qr/^\| 3 \|[^\n]*full path[^\n]*once/m, 'exit 3: the briefing\'s full path, once');
    like($skill, qr/Check first with a read/,           'exit 5: a change is checked before it is repeated');
    like($skill, qr/`ask_flashbrain` that took too long:\*\* never ask again/, 'exit 5: FlashBrain is never asked twice');
    like($skill, qr/list_pending_approvals/,            'exit 5: a slow FlashBrain run is looked up');
    unlike($skill, qr/Wait a moment and try once more/, 'exit 5: no blanket retry');

    # Flash Console asks the person before the actions that need it, and
    # the agent waits for that answer and respects a no.
    like($skill, qr/Flash Console asks the person before closing a project or phase, editing\s+documentation, asking FlashBrain, or answering a FlashBrain approval; wait\s+for that answer, and if the person declines \(exit 1\), do not try again\s+unless they ask\./,
        'the flashteams skill says Flash Console asks, to wait for it, and not to try again after a no');
    unlike($skill, qr/Ask the person before you run/, 'the agent no longer asks on top of Flash Console');

    # The task chosen in Flash Console needs its project connected.
    like($skill, qr/finds only tasks in\s+the connected project/, 'the flashteams skill connects the chosen task\'s project');

    # The optional MCP plugin's tools are not forbidden.
    like($skill, qr/FlashTeams MCP tools when the optional `flashteams-mcp`/, 'the MCP tools are allowed when installed');
    unlike($skill, qr/Never try to reach FlashTeams another way/, 'no rule against the MCP plugin');
}

# ---------------------------------------------------------------------------
# No long dashes anywhere in the repository's text.

{
    my @files;
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                $File::Find::prune = 1 if m{/\.git\z};
                push @files, $_ if -f $_;
            },
        },
        $ROOT
    );
    my @dashed = grep { slurp(substr($_, length($ROOT) + 1)) =~ /\xE2\x80\x94/ } @files;
    is("@dashed", '', 'no long dashes in any file');
}

done_testing();
