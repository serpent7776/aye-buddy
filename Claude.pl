package Claude;
# Claude.pl: everything aye-buddy has to know to run claude, behind the one
# interface every agent module provides. Loaded with require by file name from
# a closed table in aye-buddy that maps --agent claude to this file, so no
# user-supplied name ever becomes a path; nothing else there needs to know
# claude.
#
# spec($home, \%env) returns a hashref. $home is the host home directory, as
# validated by the caller (absolute, no newline); the environment is passed in
# rather than read, so a test can hand in one of its own. Every path in the
# result is a host path, and is also where the session sees the thing, since
# aye-buddy mounts each at the path it came from.
#
#   name          the word for messages ("seeding the sandbox claude state")
#   bin           the command to run; must be on the host PATH
#   args          fixed arguments, put before the user's own
#   env           variables set in the session. Their names are refused for
#                 --keep-env, so a kept host value can't quietly lose to ours.
#   config_env    the host variable that relocates config_dir when set. Named
#                 in the message when the dir it gave fails validation, and
#                 refused for --keep-env whether set or not, like env.
#   hosts         the agent's own API hosts, added to the egress allowlist;
#                 without them the session can't run
#   config_dir    the host dir holding the agent's config. It is returned as
#                 found, for the caller to validate. The per-project state dir
#                 is seeded from it and mounted over it in the session, so the
#                 agent finds its state where it always looks, and the host's
#                 own is never written.
#   seed          items under config_dir copied into the state dir on the
#                 first run, and again on --reseed; a missing one is skipped
#   seed_state    sub($build, $project_dir): run once, on the first seed, with
#                 the state dir being built and the project root. For what a
#                 plain copy can't do: here, .claude.json with its project map
#                 cut to this project. Dies with a newline-terminated message.
#   state_files   regular files that must exist in the state dir before it is
#                 mounted: created empty, mode 0600, when a seed left none;
#                 refused later when a symlink or not a regular file
#   bind_ro       items under config_dir bound read-only from the host over
#                 the state dir at the same path, after it, so a host edit is
#                 what the session runs; a missing one is skipped. A file
#                 bound stays the inode it was, so one an editor replaces
#                 mid-session reads as before until the next start
#   bind_rw       files under config_dir bound rw from the host over the state
#                 dir at the same path, after it, so a token refresh in the
#                 session lands on the host. Created empty on the host when
#                 missing, since a bind needs its source to exist.
#   state_binds   [state file, session path] pairs: a state file bound rw at a
#                 path outside config_dir, where the agent looks for it. The
#                 path is refused for a user --bind, which the mount would
#                 cover.
#   project_dir   the agent's per-project dir, named relative to the project
#                 root, bound read-only; a missing one is created, a symlink
#                 refused
#   project_overlays  dirs under project_dir given a throwaway overlay: the
#                 session sees them, and its writes vanish at exit
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);

# A path echoed in a message can carry terminal escapes; reduce it to printable
# ASCII first. Only the value goes through this, never the surrounding message.
sub printable {
    (my $s = shift) =~ s/[^\x20-\x7e]/?/g;
    return $s;
}

sub spec {
    my ($home, $env) = @_;
    # claude keeps its state under CLAUDE_CONFIG_DIR when that is set, and
    # under ~/.claude otherwise. .claude.json, the file it doesn't keep in the
    # dir, sits beside it in the default case and inside it in the other.
    my $from_env    = defined $env->{CLAUDE_CONFIG_DIR};
    my $config_dir  = $from_env ? $env->{CLAUDE_CONFIG_DIR} : "$home/.claude";
    my $claude_json = $from_env ? "$config_dir/.claude.json" : "$home/.claude.json";
    return {
        name => 'claude',
        bin  => 'claude',
        args => ['--dangerously-skip-permissions',
                 '--settings', '{"sandbox":{"enabled":false}}'],
        # Tell claude it's already inside an external sandbox so it skips the
        # workspace trust dialog (the bwrap boundary is the real trust
        # decision), and stop non-essential telemetry/error egress at the
        # source. CLAUDE_CONFIG_DIR goes along when the host has it, so the
        # session looks where the state is mounted.
        env  => {
            CLAUDE_CODE_SANDBOXED   => '1',
            DISABLE_TELEMETRY       => '1',
            DISABLE_ERROR_REPORTING => '1',
            ($from_env ? (CLAUDE_CONFIG_DIR => $config_dir) : ()),
        },
        config_env => 'CLAUDE_CONFIG_DIR',
        # Claude API and OAuth
        hosts => [qw(api.anthropic.com platform.claude.com console.anthropic.com)],
        config_dir => $config_dir,
        # What the host contributes: the config a host-side claude loads. What
        # a session writes, /config, a plugin or skill it installs, is copied,
        # so its edits stay its own; what the user writes and claude only
        # reads or runs is the host's. Transcripts, history and everything
        # else are the session's from the start.
        seed    => [qw(settings.json settings.local.json skills plugins)],
        bind_ro => [qw(CLAUDE.md mcp.json .mcp.json keybindings.json statusline-command.sh
                       commands agents output-styles rules workflows themes hooks scripts)],
        seed_state  => sub { seed_claude_json($claude_json, @_) },
        state_files => ['.claude.json', '.credentials.json'],
        # Bound rw because of OAuth token refreshes.
        bind_rw => ['.credentials.json'],
        state_binds => $from_env ? [] : [['.claude.json', $claude_json]],
        project_dir      => '.claude',
        project_overlays => ['worktrees'],
    };
}

# .claude.json holds onboarding state, the theme, MCP servers and a map keyed
# by project path. Seeded with the map cut to this project - the other entries
# name every repo the host has opened - and the session's from then on, so no
# host-side claude reads what a session wrote (user-scoped MCP servers are
# commands it would run). A host without one gets an empty file, which claude
# reads back as a fresh install.
sub seed_claude_json {
    my ($src, $build, $project_dir) = @_;
    my $doc = '';
    if (-s $src) {
        open(my $in, '<:raw', $src) or die "cannot read " . printable($src) . ": $!\n";
        my $raw = do { local $/; <$in> };
        close $in;
        require JSON::PP;   # a first run only
        my $json = JSON::PP->new->utf8->canonical;
        my $data = eval { $json->decode($raw) };
        defined $data or die "cannot parse " . printable($src) . " to seed the session's copy: "
                           . printable($@ =~ s/\s+\z//r) . "\n";
        if (ref $data eq 'HASH' && ref $data->{projects} eq 'HASH') {
            my $mine = $data->{projects}{$project_dir};
            $data->{projects} = defined $mine ? { $project_dir => $mine } : {};
        }
        $doc = $json->encode($data);
    }
    my $f = "$build/.claude.json";
    sysopen(my $out, $f, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or die "cannot create " . printable($f) . ": $!\n";
    print {$out} $doc;
    close $out or die "cannot write " . printable($f) . ": $!\n";
    return;
}

1;
