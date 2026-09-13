use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use lib 't/lib';
use AyeTest;

# Claude.pl answers, for claude, the questions aye-buddy asks of an agent.
# The spec is pinned here on its own, and then against what a run of
# aye-buddy builds from it, so the interface and its use stay in step.
require "$Bin/../Claude.pl";  ## no critic (RequireBarewordIncludes)

sub slurp { my ($f) = @_; open my $fh, '<', $f or return; local $/; return scalar <$fh> }
sub mode  { sprintf '%04o', (stat $_[0])[2] & oct('7777') }
sub spit  { my ($f, $c) = @_; open my $fh, '>', $f or die "$f: $!"; print $fh $c; close $fh }

subtest 'the spec, with the default config dir' => sub {
    my $s = Claude::spec('/h', {});
    is $s->{name}, 'claude';
    is $s->{bin},  'claude';
    is $s->{args}, ['--dangerously-skip-permissions', '--settings', '{"sandbox":{"enabled":false}}'];
    is $s->{env}, { CLAUDE_CODE_SANDBOXED => '1', DISABLE_TELEMETRY => '1',
                    DISABLE_ERROR_REPORTING => '1' }, 'no CLAUDE_CONFIG_DIR unless the host has one';
    is $s->{config_env}, 'CLAUDE_CONFIG_DIR', 'but the name is known either way';
    is $s->{hosts}, ['api.anthropic.com', 'platform.claude.com', 'console.anthropic.com'];
    is $s->{config_dir}, '/h/.claude';
    ok +(grep { $_ eq 'settings.json' } @{ $s->{seed} }), 'settings are seeded';
    ok !(grep { $_ eq 'projects' } @{ $s->{seed} }), 'transcripts are not';
    ok !(grep { m{/} } @{ $s->{seed} }), 'seed items are names under the config dir';
    ok ref $s->{seed_state} eq 'CODE', 'a seed hook';
    is $s->{state_files}, ['.claude.json', '.credentials.json'];
    is $s->{credentials}, ['.credentials.json'];
    is $s->{state_binds}, [['.claude.json', '/h/.claude.json']], '.claude.json is served beside the dir';
    is $s->{project_dir}, '.claude';
    is $s->{project_overlays}, ['worktrees'];
};

subtest 'CLAUDE_CONFIG_DIR moves the config dir' => sub {
    my $s = Claude::spec('/h', { CLAUDE_CONFIG_DIR => '/c' });
    is $s->{config_dir}, '/c', 'as found, for the caller to validate';
    is $s->{env}{CLAUDE_CONFIG_DIR}, '/c', 'forwarded into the session';
    is $s->{state_binds}, [], '.claude.json is inside the dir, no bind of its own';
    is $s->{config_env}, 'CLAUDE_CONFIG_DIR';
    $s = Claude::spec('/h', { CLAUDE_CONFIG_DIR => '' });
    is $s->{config_dir}, '', 'an empty one is passed on, not defaulted';
};

# The seed hook builds .claude.json from the host's, with the per-project map
# cut down: the other entries name every repo the host has opened.
subtest '.claude.json is seeded with the project map cut to this project' => sub {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/home", "$root/build");
    spit("$root/home/.claude.json",
         '{"theme":"dark","projects":{"/elsewhere":{"allowedTools":["x"]},"/proj":{"k":1}}}');
    my $s = Claude::spec("$root/home", {});
    ok lives { $s->{seed_state}->("$root/build", '/proj') }, 'seeds';
    my $f = "$root/build/.claude.json";
    my $data = JSON::PP->new->decode(slurp($f));
    is $data->{theme}, 'dark', 'the rest comes over';
    is $data->{projects}, { '/proj' => { k => 1 } }, 'only this project\'s entry';
    is mode($f), '0600', 'not readable by other users';
    like slurp("$root/home/.claude.json"), qr{/elsewhere}, 'the host file is untouched';
    like dies { $s->{seed_state}->("$root/build", '/proj') }, qr/\Acannot create .*\.claude\.json.*\n\z/,
        'a second seed over the first is refused';
};

subtest 'a project the host has not opened gets an empty map' => sub {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/home", "$root/build");
    spit("$root/home/.claude.json", '{"projects":{"/elsewhere":{}}}');
    Claude::spec("$root/home", {})->{seed_state}->("$root/build", '/proj');
    my $data = JSON::PP->new->decode(slurp("$root/build/.claude.json"));
    is $data->{projects}, {}, 'empty';
};

subtest 'no host .claude.json, or an empty one: an empty copy' => sub {
    for my $case (['absent', undef], ['empty', '']) {
        my ($what, $content) = @$case;
        my $root = tempdir(CLEANUP => 1);
        make_path("$root/home", "$root/build");
        spit("$root/home/.claude.json", $content) if defined $content;
        Claude::spec("$root/home", {})->{seed_state}->("$root/build", '/proj');
        my $f = "$root/build/.claude.json";
        ok -f $f, "$what: created";
        is -s $f, 0, "$what: empty";
        is mode($f), '0600', "$what: 0600";
        ok !-e "$root/home/.claude.json", 'nothing created on the host' unless defined $content;
    }
};

subtest 'an unparsable host .claude.json is refused' => sub {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/home", "$root/build");
    spit("$root/home/.claude.json", '{"theme":');
    like dies { Claude::spec("$root/home", {})->{seed_state}->("$root/build", '/proj') },
        qr/\Acannot parse .*\.claude\.json.*\n\z/, 'says why, newline-terminated';
    ok !-e "$root/build/.claude.json", 'nothing written';
};

subtest 'a host .claude.json that is not an object is copied as it is' => sub {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/home", "$root/build");
    spit("$root/home/.claude.json", '[1,2]');
    Claude::spec("$root/home", {})->{seed_state}->("$root/build", '/proj');
    is slurp("$root/build/.claude.json"), '[1,2]';
};

subtest 'with CLAUDE_CONFIG_DIR the seed reads .claude.json from there' => sub {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/home", "$root/cfg", "$root/build");
    spit("$root/home/.claude.json", '{"theme":"home"}');
    spit("$root/cfg/.claude.json",  '{"theme":"cfg"}');
    Claude::spec("$root/home", { CLAUDE_CONFIG_DIR => "$root/cfg" })->{seed_state}->("$root/build", '/proj');
    like slurp("$root/build/.claude.json"), qr/"theme":"cfg"/;
};

# What aye-buddy builds from the module's answers.
subtest 'the module agrees with aye-buddy' => sub {
    my $r = run_aye({ env => { AYE_BUDDY_DEBUG => 1 } }, '-p', 'hi');
    is $r->{exit}, 0;
    my @a = @{ $r->{argv} };
    my $home = setenv_value(\@a, 'HOME');
    my $s = Claude::spec($home, {});
    my ($i) = grep { $a[$_] eq $s->{bin} } 0 .. $#a;
    ok(defined $i, 'the payload starts with bin') or return;
    is [ @a[$i + 1 .. $i + @{ $s->{args} }] ], $s->{args}, 'then the fixed args';
    is setenv_value(\@a, $_), $s->{env}{$_}, "env $_" for sort keys %{ $s->{env} };
    my ($hosts) = $r->{err} =~ /egress allowlist: (.*)/;
    ok +(grep { $_ eq $s->{hosts}[0] } split /, /, $hosts), 'the API host is allowlisted';
    is state_dir($r), "$r->{root}/home/.local/state/aye-buddy/claude/" . state_name("$r->{root}/repo"),
        'the state dir is mounted at config_dir';
    my ($st) = grep { $a[$_] eq '--bind' && $a[$_ + 2] eq $s->{config_dir} } 0 .. $#a - 2;
    ok defined $st, 'at config_dir';
    for my $c (@{ $s->{credentials} }) {
        my $f = "$s->{config_dir}/$c";
        ok -e $f, "$c created on the host";
        my ($cr) = grep { $a[$_] eq '--bind' && $a[$_ + 1] eq $f && $a[$_ + 2] eq $f } 0 .. $#a - 2;
        ok(defined $cr && $cr > $st, "$c bound rw after the state dir");
    }
    for my $b (@{ $s->{state_binds} }) {
        my ($file, $at) = @$b;
        ok +(grep { $_->[0] eq state_dir($r) . "/$file" && $_->[1] eq $at } bwrap_binds(\@a, '--bind')),
            "$file bound rw at $at";
    }
    ok -f state_dir($r) . "/$_", "state file $_ exists" for @{ $s->{state_files} };
    my $proj = "$r->{root}/repo/$s->{project_dir}";
    ok +(grep { $_->[0] eq $proj && $_->[1] eq $proj } bwrap_binds(\@a, '--ro-bind')), 'project dir bound ro';
    ok +(grep { $_ eq "$proj/$s->{project_overlays}[0]" } overlay_dests(\@a)), 'its overlay';
};

subtest 'the module agrees with aye-buddy under CLAUDE_CONFIG_DIR' => sub {
    my $r = run_aye({ config_dir => 'cfg' });
    is $r->{exit}, 0;
    my @a = @{ $r->{argv} };
    my $s = Claude::spec(setenv_value(\@a, 'HOME'), { CLAUDE_CONFIG_DIR => "$r->{root}/cfg" });
    is setenv_value(\@a, 'CLAUDE_CONFIG_DIR'), $s->{env}{CLAUDE_CONFIG_DIR}, 'forwarded';
    ok +(grep { $_->[1] eq $s->{config_dir} } bwrap_binds(\@a, '--bind')), 'state mounted at config_dir';
    ok !(grep { $_->[1] =~ m{/\.claude\.json\z} } bwrap_binds(\@a, '--bind')), 'no .claude.json bind';
};

done_testing;
