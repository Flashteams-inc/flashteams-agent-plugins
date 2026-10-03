#!/usr/bin/perl
# Checks the marketplaces, plugin manifests, MCP servers and hooks
# configuration of both plugins against each other and against the hook.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Find qw(find);
use FindBin;
use JSON::PP;
use Test::More;

my $ROOT = abs_path("$FindBin::Bin/..");
my $CLAUDE = "plugins/claude/flashteams";
my $CODEX = "plugins/codex/flashteams";
my $MCP_URL = 'https://flashteams-mcp-server.nisitha.workers.dev/mcp';

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

my ($hook_version) = slurp('shared/hooks/flashteams-hook.pl') =~ /^our \$VERSION = '([^']+)';/m;
ok($hook_version, 'the hook names its version');

# Claude Code marketplace and plugin.
{
    my $market = json('.claude-plugin/marketplace.json');
    is($market->{name}, 'flashteams', 'Claude Code marketplace is named flashteams');
    ok($market->{owner} && $market->{owner}{name}, 'Claude Code marketplace has an owner');
    is(scalar @{ $market->{plugins} || [] }, 1, 'Claude Code marketplace lists one plugin');
    my ($entry) = @{ $market->{plugins} || [] };
    is($entry->{name},   'flashteams', 'Claude Code plugin entry is named flashteams');
    is($entry->{source}, "./$CLAUDE",  'Claude Code plugin entry points at its own folder');
    ok(!exists $entry->{version}, 'the version lives only in plugin.json');

    my $manifest = json("$CLAUDE/.claude-plugin/plugin.json");
    is($manifest->{name},    'flashteams',  'Claude Code plugin.json name');
    is($manifest->{version}, $hook_version, 'Claude Code plugin version matches the hook');
    is($manifest->{license}, 'MIT',         'Claude Code plugin license');

    my $mcp = json("$CLAUDE/.mcp.json");
    is_deeply($mcp, { mcpServers => { flashteams => { type => 'http', url => $MCP_URL } } },
        'Claude Code bundles the flashteams MCP server, with no token or header');
}

# Codex marketplace and plugin.
#
# Codex 0.160 loads a plugin's hooks only from a .codex-plugin/plugin.json
# manifest. Given a root plugin.json instead (the Agent Plugins layout), it
# still loads the skill and the MCP server but registers no hooks at all,
# even when a .codex-plugin/plugin.json sits beside it. So the Codex plugin
# has only .codex-plugin/plugin.json, and its hooks sit at hooks/hooks.json,
# where Codex looks when the manifest names no hooks.
{
    my $market = json('.agents/plugins/marketplace.json');
    is($market->{name}, 'flashteams', 'Codex marketplace is named flashteams');
    is(scalar @{ $market->{plugins} || [] }, 1, 'Codex marketplace lists one plugin');
    my ($entry) = @{ $market->{plugins} || [] };
    is($entry->{name}, 'flashteams', 'Codex plugin entry is named flashteams');
    is_deeply($entry->{source}, { source => 'local', path => "./$CODEX" }, 'Codex plugin entry points at its own folder');
    ok(!exists $entry->{version}, 'the Codex version lives only in plugin.json');
    my %installation = map { $_ => 1 } qw(NOT_AVAILABLE AVAILABLE INSTALLED_BY_DEFAULT);
    my %authentication = map { $_ => 1 } qw(ON_INSTALL ON_USE);
    ok($installation{ $entry->{policy}{installation} // '' }, 'Codex plugin entry has an installation policy');
    ok($authentication{ $entry->{policy}{authentication} // '' }, 'Codex plugin entry has an authentication policy');
    ok($entry->{category}, 'Codex plugin entry has a category');

    my $manifest = json("$CODEX/.codex-plugin/plugin.json");
    is($manifest->{name},    'flashteams',  'Codex plugin.json name');
    is($manifest->{version}, $hook_version, 'Codex plugin version matches the hook');
    is($manifest->{license}, 'MIT',         'Codex plugin license');
    ok($manifest->{description} && $manifest->{author} && $manifest->{author}{name},
        'Codex plugin.json has a description and an author');
    is($manifest->{skills},     './skills/',   'Codex plugin.json names the skills folder');
    is($manifest->{mcpServers}, './.mcp.json', 'Codex plugin.json names its MCP servers file');

    # The fields Codex's own plugin validator accepts. It rejects hooks, and
    # naming hooks would also stop Codex looking at hooks/hooks.json.
    my %known = map { $_ => 1 } qw(id name version description skills apps mcpServers interface author
                                   homepage repository license keywords);
    my @unknown = grep { !$known{$_} } sort keys %$manifest;
    is("@unknown", '', 'Codex plugin.json has only fields Codex accepts');
    ok(!exists $manifest->{hooks}, 'Codex finds the hooks at hooks/hooks.json, its default');

    my $interface = $manifest->{interface} || {};
    for my $field (qw(displayName shortDescription longDescription developerName category)) {
        ok(defined $interface->{$field} && !ref $interface->{$field} && $interface->{$field} =~ /\S/,
            "Codex plugin interface has $field");
    }
    ok(ref $interface->{capabilities} eq 'ARRAY' && !grep({ ref $_ || !/\S/ } @{ $interface->{capabilities} }),
        'Codex plugin interface lists its capabilities');
    ok(ref $interface->{defaultPrompt} eq 'ARRAY' && @{ $interface->{defaultPrompt} } >= 1
          && @{ $interface->{defaultPrompt} } <= 3, 'Codex plugin interface has one to three starter prompts');
    like($interface->{websiteURL} // '', qr{\Ahttps://}, 'Codex plugin website is https');

    my $mcp = json("$CODEX/.mcp.json");
    is_deeply($mcp, { mcpServers => { flashteams => { type => 'http', url => $MCP_URL } } },
        'Codex bundles the flashteams MCP server, with no token or header');

    ok(-f "$ROOT/$CODEX/hooks/hooks.json", 'the Codex hooks are at hooks/hooks.json');
    ok(-f "$ROOT/$CODEX/skills/flashteams-next-task/SKILL.md", 'the Codex skill is under skills/');
}

# Neither agent can load the other's manifest. The Codex plugin has no root
# plugin.json, which would make Codex skip its hooks, and no mcp.json, which
# Codex would not read from this layout.
ok(!-e "$ROOT/$CLAUDE/$_", "the Claude Code plugin has no $_") for qw(plugin.json mcp.json .codex-plugin);
ok(!-e "$ROOT/$CODEX/$_", "the Codex plugin has no $_") for qw(.claude-plugin plugin.json mcp.json);

# Hooks: every command starts the shared hook with the right agent and the
# event it is registered for.
my %HOOKS = (
    claude => {
        file   => "$CLAUDE/hooks/hooks.json",
        root   => 'CLAUDE_PLUGIN_ROOT',
        events => [qw(SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure
                      PermissionRequest Notification Stop StopFailure)],
        matchers => {
            PreToolUse   => 'AskUserQuestion',
            Notification => 'permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog',
        },
    },
    codex => {
        file     => "$CODEX/hooks/hooks.json",
        root     => 'PLUGIN_ROOT',
        events   => [qw(SessionStart UserPromptSubmit PreToolUse PostToolUse PermissionRequest Stop Interrupt)],
        matchers => { PreToolUse => '^request_user_input$' },
    },
);
for my $agent (sort keys %HOOKS) {
    my $spec = $HOOKS{$agent};
    my $config = json($spec->{file});
    is_deeply([sort keys %{ $config->{hooks} || {} }], [sort @{ $spec->{events} }], "$agent hooks the expected events");
    for my $event (sort keys %{ $config->{hooks} || {} }) {
        my $groups = $config->{hooks}{$event};
        is(scalar @$groups, 1, "$agent $event has one matcher group");
        is($groups->[0]{matcher}, $spec->{matchers}{$event}, "$agent $event matcher");
        my @handlers = @{ $groups->[0]{hooks} };
        is(scalar @handlers, 1, "$agent $event has one handler");
        my $handler = $handlers[0];
        is($handler->{type}, 'command', "$agent $event is a command hook");
        is($handler->{command}, qq{sh "\${$spec->{root}}/hooks/flashteams-hook.sh" $agent $event},
            "$agent $event starts the shared hook");
        ok(!exists $handler->{args}, "$agent $event runs through sh, so a missing Perl stays quiet");
        ok(!$handler->{async}, "$agent $event runs in order");
        cmp_ok($handler->{timeout}, '<=', 5, "$agent $event has a short timeout");
    }
}

# The copies in each plugin match shared/.
for my $plugin ($CLAUDE, $CODEX) {
    for my $file (qw(hooks/flashteams-hook.pl hooks/flashteams-hook.sh)) {
        (my $shared = $file) =~ s{^}{shared/};
        is(slurp("$plugin/$file"), slurp($shared), "$plugin/$file matches $shared (run script/sync)");
    }
    my $skill = 'skills/flashteams-next-task/SKILL.md';
    is(slurp("$plugin/$skill"), slurp("shared/$skill"), "$plugin/$skill matches shared/$skill (run script/sync)");
}

# The skill names itself and says when to use it.
{
    my $skill = slurp('shared/skills/flashteams-next-task/SKILL.md');
    like($skill, qr/\A---\nname: flashteams-next-task\ndescription: \S[^\n]+\n---\n/, 'the skill has its frontmatter');
    like($skill, qr/find_tasks/,  'the skill finds the task');
    like($skill, qr/load_task/,   'the skill loads the briefing');
    like($skill, qr/`start`/,     'the skill starts the task before working');
    like($skill, qr/actual_hours/, 'the skill says how to log time');
}

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
