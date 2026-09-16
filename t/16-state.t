use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;
use Cwd qw(abs_path);
use Fcntl qw(LOCK_SH LOCK_EX LOCK_UN);
use File::Path qw(remove_tree);
use JSON::PP ();

sub slurp { my ($f) = @_; open my $fh, '<', $f or return; local $/; scalar <$fh> }
sub mode  { sprintf('%04o', (stat $_[0])[2] & oct('7777')) }
sub rw_binds { map { bwrap_binds($_[0]{argv}, $_) } qw(--bind --bind-try) }
sub all_mounts { map { bwrap_binds($_[0]{argv}, $_) } qw(--bind --bind-try --ro-bind --ro-bind-try) }

# The session's claude state is a dir of aye-buddy's own, one per project,
# mounted where claude looks for it. The host's ~/.claude is never mounted: a
# regression there hands a session every other project's transcripts, or a
# host-side claude what a session wrote.
subtest 'a state dir of our own is bound rw at ~/.claude, nothing of the host under it' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my $home  = setenv_value($r->{argv}, 'HOME');
    my $state = state_dir($r);
    ok(defined $state, 'something is bound at ~/.claude') or return;
    like $state, qr{\A\Q$r->{root}\E/home/\.local/state/aye-buddy/claude/[^/]+\z},
        'under the state root, in a dir for the agent';
    ok -d $state, 'created';
    is mode($_), '0700', "$_ is 0700" for "$r->{root}/home/.local/state/aye-buddy", $state;

    my @a = @{$r->{argv}};
    ok !(grep { $a[$_] eq '--tmpfs' && $a[$_ + 1] eq "$home/.claude" } 0 .. $#a - 1),
        'no tmpfs over it';
    ok !(grep { m{\A\Q$home\E/\.claude} } overlay_dests($r->{argv})), 'no overlay under it';
    my @from_host = grep { $_->[0] =~ m{\A\Q$home\E/\.claude} } all_mounts($r);
    is [map { $_->[0] } @from_host], ["$home/.claude/.credentials.json"],
        'the token is the only host path mounted from ~/.claude';
    ok !(grep { $_->[1] =~ m{/memory\z} } @from_host), 'and no memory pin: memory is the session\'s';
    ok +(grep { $_ eq "$home/.claude" } setenv_list($r->{argv}, 'LL_RW')), 'in LL_RW';
};

# Pinned by example rather than derived with the implementation's rule, which
# would follow any change to it, including a wrong one.
subtest 'the state dir is named after the project path' => sub {
    my $r = run_aye({ repo_name => 'my-proj_v2' });
    is $r->{exit}, 0;
    my ($name) = state_dir($r) =~ m{/([^/]+)\z};
    like $name, qr{\A-.*-my__proj_-v2\z}, q{'/' is '-', '-' is '__', '_' is '_-'};
    is $name, state_name(abs_path("$r->{root}/my-proj_v2")), 'as the harness derives it';
};

# The point of the escapes: a dash, a slash and an underscore are told apart,
# so no two project paths land in one state dir.
subtest 'paths that differ only in dashes, slashes and underscores get their own dirs' => sub {
    my %seen;
    for my $name ('a-b', 'a/b', 'a_b') {
        my $r = run_aye({ repo_name => $name });
        is $r->{exit}, 0, "$name runs";
        my ($n) = state_dir($r) =~ m{/([^/]+)\z};
        my $prefix = state_name(abs_path($r->{root}));
        $n =~ s/\A\Q$prefix\E// or die "unexpected name $n";
        $seen{$n}++;
    }
    is [sort keys %seen], ['-a-b', '-a_-b', '-a__b'], 'three distinct names';
};

subtest 'a project path too long for one name is refused' => sub {
    my $r = run_aye({ repo_name => 'd' x 250 });
    is $r->{exit}, 1;
    like $r->{err}, qr/too long to name a state dir after/, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
};

subtest 'XDG_STATE_HOME moves the state root' => sub {
    my $r = run_aye({ state_home => 'st' });
    is $r->{exit}, 0;
    like state_dir($r), qr{\A\Q$r->{root}\E/st/aye-buddy/claude/}, 'under it';
};

# A relative one is invalid per the spec.
subtest 'a relative XDG_STATE_HOME is ignored' => sub {
    my $r = run_aye({ env => { XDG_STATE_HOME => 'st' } });
    is $r->{exit}, 0;
    like state_dir($r), qr{/home/\.local/state/aye-buddy/claude/}, 'the default is used';
};

# What a session writes of a host-side claude's config comes over as a copy,
# so its edits are its own. Transcripts, history and the like are the host's
# business and other projects' secrets, and stay out.
my %host = (
    'home/.claude/settings.json'             => '{"a":1}',
    'home/.claude/settings.local.json'       => '{"b":1}',
    'home/.claude/skills/one/SKILL.md'       => 'skill',
    'home/.claude/skills/one/run.sh'         => "#!/bin/sh\n",
    'home/.claude/plugins/p/x'               => 'plugin',
    'home/.claude/history.jsonl'             => 'prompts',
    'home/.claude/projects/-other/x.jsonl'   => 'other transcripts',
    'home/.claude/config.json'               => 'stale credentials',
);
subtest 'the host config a session writes is copied in, the rest of ~/.claude is not' => sub {
    my $r = run_aye({ files => \%host, modes => { 'home/.claude/skills/one/run.sh' => oct('755') } });
    is $r->{exit}, 0;
    like $r->{err}, qr/\Aaye-buddy: seeding the sandbox claude state/, 'says so on the first run';
    my $s = state_dir($r);
    is slurp("$s/settings.json"), '{"a":1}', 'settings copied';
    is slurp("$s/settings.local.json"), '{"b":1}', 'local settings copied';
    is slurp("$s/skills/one/SKILL.md"), 'skill', 'skills copied, whole';
    is slurp("$s/plugins/p/x"), 'plugin', 'plugins copied';
    is mode("$s/skills/one/run.sh"), '0755', 'exec bit kept';
    ok !-e "$s/$_", "$_ not copied" for qw(history.jsonl projects config.json);
};

# Per dir, not per item: what a session removed stays removed, and what the
# host gained later stays out, until asked for with --reseed.
subtest 'the copy is made once' => sub {
    my $r = run_aye({ files => { 'home/.claude/settings.json' => 'v1',
                                 'home/.claude/plugins/p/x' => 'plugin' } });
    is $r->{exit}, 0;
    my $s = state_dir($r);
    unlink "$s/plugins/p/x" and rmdir "$s/plugins/p" and rmdir "$s/plugins" or die $!;
    $r = run_aye({ root => $r->{root}, files => { 'home/.claude/settings.json' => 'v2',
                                                  'home/.claude/settings.local.json' => 'new' } });
    is $r->{exit}, 0;
    is state_dir($r), $s, 'the same dir';
    unlike $r->{err}, qr/seeding/, 'no seeding message the second time';
    is slurp("$s/settings.json"), 'v1', 'the session\'s copy is left alone';
    ok !-e "$s/plugins", 'a dir the session removed stays removed';
    ok !-e "$s/settings.local.json", 'a file the host gained stays out';
};

# What the user writes and claude only reads or runs, CLAUDE.md, hooks,
# scripts and the rest, is bound from the host over the copy, read-only, so
# an edit there is what the session runs, and a session can't change what a
# host-side claude runs.
subtest 'the config the user writes is bound from the host, read-only, over the state dir' => sub {
    my $r = run_aye({ files => { 'home/.claude/hooks/h.sh' => 'hook', 'home/.claude/scripts/s.pl' => 'script',
                                 'home/.claude/CLAUDE.md' => 'rules' } });
    is $r->{exit}, 0;
    my $home = setenv_value($r->{argv}, 'HOME');
    my $s = state_dir($r);
    ok !-e "$s/$_", "$_ not copied" for qw(hooks scripts CLAUDE.md);
    my @a = @{$r->{argv}};
    my ($state_at) = grep { $a[$_] eq '--bind' && $a[$_ + 2] eq "$home/.claude" } 0 .. $#a - 2;
    for my $item (qw(hooks scripts CLAUDE.md)) {
        my @b = grep { $_->[0] eq "$home/.claude/$item" } bwrap_binds($r->{argv}, '--ro-bind');
        is \@b, [["$home/.claude/$item", "$home/.claude/$item"]], "$item bound ro at its path";
        my ($at) = grep { $a[$_] eq '--ro-bind' && $a[$_ + 1] eq "$home/.claude/$item" } 0 .. $#a - 1;
        ok $at > $state_at, "$item after the state dir, so over it";
        ok +(grep { $_ eq "$home/.claude/$item" } setenv_list($r->{argv}, 'LL_RO')), "$item in LL_RO";
    }
    ok !(grep { $_->[0] =~ m{\A\Q$home\E/\.claude/(hooks|scripts|CLAUDE\.md)} } rw_binds($r)), 'never rw';
};

subtest 'an item bound read-only the host lacks is not bound' => sub {
    my $r = run_aye({ files => { 'home/.claude/hooks/h.sh' => 'hook' } });
    is $r->{exit}, 0;
    my $home = setenv_value($r->{argv}, 'HOME');
    ok !(grep { $_->[0] eq "$home/.claude/scripts" } all_mounts($r)), 'no scripts on the host, no bind';
};

# The bind follows the link, as the copy does for a seeded item.
subtest 'a symlinked read-only item is bound' => sub {
    my $r = run_aye({ files => { 'dotfiles/scripts/s.pl' => 'x' },
                      links => { 'home/.claude/scripts' => '../../dotfiles/scripts' } });
    is $r->{exit}, 0;
    my $home = setenv_value($r->{argv}, 'HOME');
    ok +(grep { $_->[0] eq "$home/.claude/scripts" } bwrap_binds($r->{argv}, '--ro-bind')), 'bound';
};

subtest 'an item bound read-only linked into other projects\' state, or dangling, is not bound' => sub {
    my $r = run_aye({ dirs => ['home/.claude/projects/-other'],
                      links => { 'home/.claude/hooks' => 'projects/-other', 'home/.claude/scripts' => 'nowhere' } });
    is $r->{exit}, 0, 'still launches';
    my $home = setenv_value($r->{argv}, 'HOME');
    like $r->{err}, qr/warning: not bound: .*hooks points at .*-other,\n  which holds other projects' state/, 'says so';
    like $r->{err}, qr/warning: not bound: .*scripts is a dangling symlink/, 'and for the dangling one';
    ok !(grep { $_->[0] =~ m{\A\Q$home\E/\.claude/(hooks|scripts)\z} } all_mounts($r)), 'neither bound';
};

# bwrap can't mount a dir over a file or the reverse, and follows a link at
# the mount point; a session can leave any of those where the host's item is
# bound, and the start would die in bwrap with nothing said.
subtest 'a mount point of the other kind, or a link, where a host item is bound is refused' => sub {
    my @cases = (
        ['scripts',   sub { open my $fh, '>', shift or die $!; close $fh }, 'home/.claude/scripts/s.pl',
         qr/scripts is a file where the host's is a directory; --reseed removes it/],
        ['CLAUDE.md', sub { mkdir shift or die $! },                        'home/.claude/CLAUDE.md',
         qr/CLAUDE\.md is a directory where the host's is a file; --reseed removes it/],
        ['hooks',     sub { symlink 'projects', shift or die $! },          'home/.claude/hooks/h.sh',
         qr/hooks is a symlink; --reseed removes it/],
    );
    for my $case (@cases) {
        my ($item, $leave, $host_file, $why) = @$case;
        my $r = run_aye({ files => { 'home/.claude/settings.json' => 'v1' } });
        is $r->{exit}, 0, "$item: a first run";
        my $s = state_dir($r);
        $leave->("$s/$item");
        $r = run_aye({ root => $r->{root}, files => { $host_file => 'x' } });
        is $r->{exit}, 1, "$item: exits 1 once the host has the item";
        like $r->{err}, qr/aye-buddy: .*$why/, "$item: says why";
        is $r->{argv}, [], "$item: bwrap never invoked";
        $r = run_aye({ root => $r->{root} }, '--reseed');
        is $r->{exit}, 0, "$item: --reseed clears it";
        ok !-e "$s/$item" && !-l "$s/$item", "$item: gone";
    }
};

# A run that dies halfway through the copy must not leave a dir the next run
# takes for a seeded one: the build goes under another name until complete.
subtest 'a failed seed leaves no state dir behind' => sub {
    my $r = run_aye({ files => { 'home/.claude/plugins/a/x' => 'a', 'home/.claude/plugins/b/x' => 'b' },
                      modes => { 'home/.claude/plugins/b' => 0 } });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/aye-buddy: cannot copy .*plugins/, 'names the item';
    my $root = "$r->{root}/home/.local/state/aye-buddy/claude";
    my ($name) = grep { !/_new\z/ && !/_lock\z/ } do { opendir my $d, $root or die; grep { !/^\./ } readdir $d };
    ok !defined $name, 'no state dir' or diag $name;
    chmod oct('755'), "$r->{root}/home/.claude/plugins/b" or die $!;
    $r = run_aye({ root => $r->{root} });
    is $r->{exit}, 0, 'the next run seeds';
    like $r->{err}, qr/seeding/, 'from scratch';
    my $s = state_dir($r);
    is slurp("$s/plugins/b/x"), 'b', 'whole';
    ok !-e "${s}_new", 'and the build name is gone';
};

# The build and staging name and the lock file sit beside the state dir, so
# they must be names no project can get.
subtest 'a project whose path ends like the build or lock name keeps its state' => sub {
    for my $sibling ('repo.new', 'repo_new', 'repo.lock', 'repo_lock') {
        my $r = run_aye({ repo_name => $sibling, files => { 'home/.claude/settings.json' => 'v1' } });
        is $r->{exit}, 0, "$sibling: launches";
        my $s = state_dir($r);
        mkdir "$s/projects" or die $!;
        $r = run_aye({ root => $r->{root}, repo_name => 'repo' });
        is $r->{exit}, 0, 'repo: launches beside it';
        $r = run_aye({ root => $r->{root}, repo_name => 'repo' }, '--reseed');
        is $r->{exit}, 0, 'repo: reseeds beside it';
        ok -d "$s/projects", "$sibling: its state is untouched";
        $r = run_aye({ root => $r->{root}, repo_name => $sibling });
        is $r->{exit}, 0, "$sibling: launches again";
    }
};

subtest '--reseed replaces the host-config part and keeps the session\'s own' => sub {
    my $r = run_aye({ files => { 'home/.claude/settings.json' => 'v1',
                                 'home/.claude/settings.local.json' => 'local',
                                 'home/.claude/skills/one/SKILL.md' => 'skill',
                                 'home/.claude/.claude.json' => 'x' } });
    is $r->{exit}, 0;
    my $s = state_dir($r);
    # What a session leaves behind
    mkdir "$s/projects" or die $!;
    mkdir "$s/skills/mine" or die $!;
    open my $fh, '>', "$s/skills/mine/SKILL.md" or die $!; print $fh 'made in-session'; close $fh;
    open $fh, '>', "$s/.claude.json" or die $!; print $fh '{"session":1}'; close $fh;
    # A copy of hooks/ from before it was bound from the host, and the mount
    # point bwrap makes for a file item; both show once the host drops the item
    mkdir "$s/hooks" or die $!;
    open $fh, '>', "$s/hooks/h.sh" or die $!; print $fh 'old'; close $fh;
    open $fh, '>', "$s/keybindings.json" or die $!; close $fh;
    unlink "$r->{root}/home/.claude/settings.local.json" or die $!;
    $r = run_aye({ root => $r->{root}, files => { 'home/.claude/settings.json' => 'v2' } }, '--reseed');
    is $r->{exit}, 0;
    like $r->{err}, qr/\Aaye-buddy: reseeding the sandbox claude state/, 'says so';
    is slurp("$s/settings.json"), 'v2', 'settings replaced';
    ok !-e "$s/settings.local.json", 'a file gone from the host is gone here';
    ok !-e "$s/hooks", 'an old copy at a bound path is removed';
    ok !-e "$s/keybindings.json", 'a mount point too';
    ok !-e "$s/skills/mine", 'a session-made skill goes with its dir';
    is slurp("$s/skills/one/SKILL.md"), 'skill', 'the host one is back';
    ok -d "$s/projects", 'transcripts kept';
    is slurp("$s/.claude.json"), '{"session":1}', '.claude.json kept';
};

# The whole seed set is staged before anything is swapped, so a copy that
# fails leaves the state dir untouched, and the staging dir is cleared by the
# next --reseed rather than mistaken for anything.
subtest 'a --reseed whose copy fails leaves the state dir as it was' => sub {
    my $r = run_aye({ files => { 'home/.claude/settings.json' => 'v1',
                                 'home/.claude/skills/one/SKILL.md' => 'skill' } });
    is $r->{exit}, 0;
    my $s = state_dir($r);
    $r = run_aye({ root => $r->{root}, files => { 'home/.claude/settings.json' => 'v2',
                                                  'home/.claude/plugins/b/x' => 'b' },
                   modes => { 'home/.claude/plugins/b' => 0 } }, '--reseed');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/aye-buddy: cannot copy .*plugins/, 'names the item';
    is slurp("$s/settings.json"), 'v1', 'settings untouched';
    is slurp("$s/skills/one/SKILL.md"), 'skill', 'skills untouched';
    ok !-e "$s/plugins", 'nothing half-swapped in';
    ok -d "${s}_new", 'the staging dir is left for inspection';
    $r = run_aye({ root => $r->{root} });
    is $r->{exit}, 0, 'a plain run still launches';
    ok -d "${s}_new", 'and leaves the staging dir alone';
    is slurp("$s/settings.json"), 'v1', 'without reseeding';
    chmod oct('755'), "$r->{root}/home/.claude/plugins/b" or die $!;
    $r = run_aye({ root => $r->{root} }, '--reseed');
    is $r->{exit}, 0, 'the next --reseed goes through';
    ok !-e "${s}_new", 'and clears the staging dir';
    is slurp("$s/settings.json"), 'v2', 'reseeded';
};

subtest '--reseed after the agent args is a misplaced-flag error' => sub {
    my $r = run_aye('-p', 'hi', '--reseed');
    is $r->{exit}, 1;
    like $r->{err}, qr/--reseed is an aye-buddy flag/, 'named';
    is $r->{argv}, [], 'bwrap never invoked';
};

# A dotfiles manager leaves ~/.claude/skills as a symlink into its repo; the
# copy follows it, since the session can't.
subtest 'a symlinked host config dir is copied as a real one' => sub {
    my $r = run_aye({ files => { 'dotfiles/skills/s/SKILL.md' => 'x' },
                      links => { 'home/.claude/skills' => '../../dotfiles/skills' } });
    is $r->{exit}, 0;
    my $s = state_dir($r);
    ok -d "$s/skills" && !-l "$s/skills", 'a real dir';
    is slurp("$s/skills/s/SKILL.md"), 'x', 'with the target\'s content';
};

subtest 'a dangling symlink is skipped with a warning' => sub {
    my $r = run_aye({ links => { 'home/.claude/skills' => 'nowhere' } });
    is $r->{exit}, 0, 'still launches';
    like $r->{err}, qr/warning: not seeded: .*skills is a dangling symlink/, 'says which';
    ok !-e state_dir($r) . '/skills', 'and nothing is there';
};

# Below the item, links are copied as links: following them would let a link
# under skills/ pull ~/.ssh or another project's transcripts into the state
# dir, and a loop would never end. Dangling ones are what the session had
# before, when the target was simply not mounted.
subtest 'a symlink below the item is copied as a link, not followed' => sub {
    my $r = run_aye({ files => { 'home/.claude/skills/a/SKILL.md' => 'x', 'secret' => 'key' },
                      links => { 'home/.claude/skills/a/link' => '../../../../secret',
                                 'home/.claude/skills/a/loop' => '..' } });
    is $r->{exit}, 0, 'still launches';
    my $s = state_dir($r);
    is slurp("$s/skills/a/SKILL.md"), 'x', 'the file next to them is copied';
    ok -l "$s/skills/a/link", 'the link is a link';
    is readlink("$s/skills/a/link"), '../../../../secret', 'with the same target';
    ok -l "$s/skills/a/loop", 'the loop too';
};

# The item itself is followed, but not into what holds other projects' state.
subtest 'an item linked at the claude dir, its projects or the state root is skipped' => sub {
    for my $target ('.', 'projects', 'projects/-other', '../.local/state/aye-buddy') {
        my $r = run_aye({ dirs => ['home/.local/state/aye-buddy', 'home/.claude/projects/-other'],
                          links => { 'home/.claude/skills' => $target } });
        is $r->{exit}, 0, "$target: still launches";
        like $r->{err}, qr/warning: not seeded: .*skills points at/, "$target: says so";
        ok !-e state_dir($r) . '/skills', "$target: nothing copied";
    }
};

# The mode goes on after the dir is filled, or a read-only one would refuse
# its own content.
subtest 'a read-only host dir comes over read-only, with its content' => sub {
    my $r = run_aye({ files => { 'home/.claude/skills/ro/SKILL.md' => 'x' },
                      modes => { 'home/.claude/skills/ro' => oct('555') } });
    is $r->{exit}, 0;
    my $s = state_dir($r);
    is slurp("$s/skills/ro/SKILL.md"), 'x', 'content copied';
    is mode("$s/skills/ro"), '0555', 'mode kept';
    chmod oct('755'), "$s/skills/ro", "$r->{root}/home/.claude/skills/ro";   # let CLEANUP work
};

# .claude.json is seeded from the host's, with the per-project map cut down:
# the other entries name every repo the host has opened. Bound at ~/.claude.json
# from the state dir, so the host file is never written.
subtest '.claude.json is seeded with the project map cut to this project' => sub {
    my $r = run_aye({ files => { 'home/.claude.json' =>
        '{"theme":"dark","projects":{"/elsewhere":{"allowedTools":["x"]},"@ROOT@/repo":{"k":1}}}' } });
    is $r->{exit}, 0;
    my $home = setenv_value($r->{argv}, 'HOME');
    my $s = state_dir($r);
    my $data = JSON::PP->new->decode(slurp("$s/.claude.json"));
    is $data->{theme}, 'dark', 'the rest comes over';
    is $data->{projects}, { "$r->{root}/repo" => { k => 1 } }, 'only this project\'s entry';
    is mode("$s/.claude.json"), '0600', 'not readable by other users';
    ok +(grep { $_->[0] eq "$s/.claude.json" && $_->[1] eq "$home/.claude.json" } rw_binds($r)),
        'bound rw at ~/.claude.json';
    ok !(grep { $_->[0] eq "$home/.claude.json" } all_mounts($r)), 'the host file is not';
    like slurp("$home/.claude.json"), qr{/elsewhere}, 'and is untouched';
};

subtest 'a project the host has not opened gets an empty map' => sub {
    my $r = run_aye({ files => { 'home/.claude.json' => '{"projects":{"/elsewhere":{}}}' } });
    is $r->{exit}, 0;
    my $data = JSON::PP->new->decode(slurp(state_dir($r) . '/.claude.json'));
    is $data->{projects}, {}, 'empty';
};

# The bind needs its source to exist; an empty file reads back as a fresh
# install, which is what a host with no .claude.json is.
subtest 'no host .claude.json: an empty one is created' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my $f = state_dir($r) . '/.claude.json';
    ok -f $f, 'created';
    is -s $f, 0, 'empty';
    ok !-e "$r->{root}/home/.claude.json", 'nothing created on the host';
};

subtest 'an unparsable host .claude.json is refused' => sub {
    my $r = run_aye({ files => { 'home/.claude.json' => '{"theme":' } });
    is $r->{exit}, 1;
    like $r->{err}, qr/cannot parse .*\.claude\.json/, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
};

# A bind needs its source to exist, and an OAuth login in-session writes through
# it to the host inode — so an absent credentials file is created, not skipped.
# It lands over the state dir bind, so the host token is what claude finds there.
subtest 'the credentials file is created and bound rw over the state dir' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my $creds = "$r->{root}/home/.claude/.credentials.json";
    ok -e $creds, 'created on the host when absent';
    is -s $creds, 0, 'empty, so claude reads it back as logged out';
    is mode($creds), '0600', 'and not readable by other users';
    my @a = @{$r->{argv}};
    my $home = setenv_value($r->{argv}, 'HOME');
    my ($st) = grep { $a[$_] eq '--bind' && $a[$_ + 2] eq "$home/.claude" } 0 .. $#a - 2;
    my ($cr) = grep { $a[$_] eq '--bind' && $a[$_ + 1] eq $creds && $a[$_ + 2] eq $creds } 0 .. $#a - 2;
    ok(defined $st && defined $cr, 'both bound rw') or return;
    ok $cr > $st, 'the token after the state dir, so it wins';
    my $mp = state_dir($r) . '/.credentials.json';
    ok -f $mp, 'its mount point exists in the state dir';
    is -s $mp, 0, 'empty';
    is mode($mp), '0600', 'and 0600';
};

# claude keeps its state under CLAUDE_CONFIG_DIR when that is set: the seed
# comes from there, the state dir is mounted there, and .claude.json is inside
# it, where claude looks.
subtest 'CLAUDE_CONFIG_DIR moves the claude state root' => sub {
    my $r = run_aye({ config_dir => 'cfg',
                      files => { 'cfg/settings.json' => 'cfg', 'cfg/.claude.json' => '{"theme":"x"}',
                                 'home/.claude/settings.json' => 'home', 'home/.claude.json' => '{}' } });
    is $r->{exit}, 0;
    my $cfg  = "$r->{root}/cfg";
    my $home = setenv_value($r->{argv}, 'HOME');
    is setenv_value($r->{argv}, 'CLAUDE_CONFIG_DIR'), $cfg, 'forwarded to the session';
    my $s = state_dir($r);
    ok(defined $s, 'the state dir is bound there') or return;
    is slurp("$s/settings.json"), 'cfg', 'seeded from there';
    like slurp("$s/.claude.json"), qr/"theme":"x"/, '.claude.json too';
    ok !(grep { $_->[1] =~ m{/\.claude\.json\z} } all_mounts($r)),
        'no bind for .claude.json: it is inside the state dir';
    ok +(grep { $_->[0] eq "$cfg/.credentials.json" } rw_binds($r)), 'credentials bound from there';
    ok -e "$cfg/.credentials.json", 'credentials file created there';
    ok !(grep { $_->[1] =~ m{\A\Q$home\E/\.claude} } all_mounts($r)), 'nothing bound under ~/.claude';
    my @a = @{$r->{argv}};
    ok !(grep { $a[$_] eq '--tmpfs' && $a[$_ + 1] eq $cfg } 0 .. $#a - 1), 'no tmpfs of its own';
};

# A state root under a path the session sees hands every project's state to
# any session; a bind over it would put it back wholesale; and one at the
# claude state dir would seed from itself.
subtest 'a state root the session would see is refused' => sub {
    for my $case (
        ['under the project',        { state_home => 'repo/state' }],
        ['under the cache dir',      { state_home => 'home/.cache' }],
        ['at the claude state dir',  { config_dir => 'home/.local/state/aye-buddy' }],
    ) {
        my ($what, $opts) = @$case;
        my $r = run_aye($opts);
        is $r->{exit}, 1, "$what: exits 1";
        like $r->{err}, qr/overlaps/, "$what: says why";
        is $r->{argv}, [], "$what: bwrap never invoked";
    }
    my $r = run_aye({ dirs => ['home/.local/state'] }, '--bind-ro', '../home/.local/state');
    is $r->{exit}, 1, 'an extra bind of an ancestor: exits 1';
    like $r->{err}, qr/overlaps/, 'says why';
    $r = run_aye({ env => { XDG_STATE_HOME => '/usr/aye-buddy-test' } });
    is $r->{exit}, 1, 'under a system dir: exits 1';
    like $r->{err}, qr/overlaps \/usr/, 'says why';
};

# The guard runs before anything is created, or a refused root inside the
# repo would still appear there.
subtest 'a refused state root is not created' => sub {
    my $r = run_aye({ state_home => 'repo/state' });
    is $r->{exit}, 1;
    ok !-e "$r->{root}/repo/state", 'nothing under the repo';
};

# ~/.claude.json is served from the state dir; an explicit bind of the host
# file would be silently covered by that mount.
subtest 'an extra bind of ~/.claude.json is refused' => sub {
    my $r = run_aye({ files => { 'home/.claude.json' => '{}' } }, '--bind', '../home/.claude.json');
    is $r->{exit}, 1;
    like $r->{err}, qr/\.claude\.json, where the sandbox mounts/, 'says why';
    is $r->{argv}, [], 'bwrap never invoked';
};

# --reseed pulls the seeded dirs out from under a running session; the lock
# beside the state dir is what stops it. The harness bwrap exits at once, so
# the held lock is planted by hand here.
subtest 'the state lock keeps --reseed and a running session apart' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my $lock = state_dir($r) . '_lock';
    ok -f $lock, 'the lock file sits beside the state dir';
    open my $fh, '<', $lock or die $!;
    flock $fh, LOCK_SH or die $!;    # a running session
    my $r2 = run_aye({ root => $r->{root} }, '--reseed');
    is $r2->{exit}, 1, '--reseed with a session running: exits 1';
    like $r2->{err}, qr/a session is running in this project/, 'says why';
    $r2 = run_aye({ root => $r->{root} });
    is $r2->{exit}, 0, 'a second session alongside is fine';
    flock $fh, LOCK_EX or die $!;    # a reseed in progress
    $r2 = run_aye({ root => $r->{root} });
    is $r2->{exit}, 1, 'a session during a reseed: exits 1';
    like $r2->{err}, qr/seeding this project/, 'says why';
    flock $fh, LOCK_UN;
    $r2 = run_aye({ root => $r->{root} }, '--reseed');
    is $r2->{exit}, 0, 'and once released, --reseed goes ahead';
};

# Two first runs at once would build over each other; a first seed holds the
# lock exclusively, like --reseed, and drops to shared once the dir is in place.
subtest 'a first seed holds the state lock exclusively' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my $s = state_dir($r);
    remove_tree($s);
    ok !-e $s, 'state dir gone; the next run seeds';
    open my $fh, '<', "${s}_lock" or die $!;
    flock $fh, LOCK_SH or die $!;    # another first run, mid-copy
    my $r2 = run_aye({ root => $r->{root} });
    is $r2->{exit}, 1, 'a first seed alongside a held lock: exits 1';
    like $r2->{err}, qr/another aye-buddy is seeding this project/, 'says why';
    ok !-e $s, 'and built nothing';
    flock $fh, LOCK_UN;
    $r2 = run_aye({ root => $r->{root} });
    is $r2->{exit}, 0, 'and once released, the seed goes ahead';
    like $r2->{err}, qr/seeding/, 'from scratch';
};

# The lock is on an fd. Handed to the session, a flock there could drop it
# and let a --reseed pull the config out from under the running session.
subtest 'the state lock fd is not handed to the session' => sub {
    for my $mode ([], ['--no-net-filter']) {
        my $r = run_aye(@$mode);
        is $r->{exit}, 0, "@$mode";
        ok +(grep { $_ eq "$r->{root}/out" } @{ $r->{fds} }), 'the stub reported its fds';
        my $lock = state_dir($r) . '_lock';
        ok !(grep { $_ eq $lock } @{ $r->{fds} }), 'none of them is the lock';
    }
};

# aye-buddy waits on the session instead, so its status still comes through.
subtest 'the session\'s exit status is aye-buddy\'s' => sub {
    for my $mode ([], ['--no-net-filter']) {
        my $r = run_aye({ bwrap_status => 3 }, @$mode);
        is $r->{exit}, 3, "@$mode";
    }
};

# A bind follows symlinks: the target would be mounted, writable.
subtest 'a symlinked state dir is refused' => sub {
    my $r = run_aye({ state_link => 'elsewhere' });
    is $r->{exit}, 1;
    like $r->{err}, qr/is a symlink/, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
    ok !-e "$r->{root}/home/.local/state/aye-buddy/claude/" . state_name(abs_path("$r->{root}/repo")) . '_lock',
        'and no lock file was made for it';
};

# Every check that can refuse the run comes before the state dir is built, so
# a refused run leaves nothing under the state root.
subtest 'a run refused after the guards leaves no state behind' => sub {
    my $r = run_aye({ repo_claude_link => 'elsewhere', files => { 'home/.claude/settings.json' => 'x' } });
    is $r->{exit}, 1;
    like $r->{err}, qr/\.claude is a symlink/, 'refused on the project .claude';
    ok !-e "$r->{root}/home/.local/state", 'not even the state root was created';
};

# The session owns the state dir, so what it left there is checked before the
# next run binds it.
subtest 'a symlink or directory where the state files go is refused' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my $s = state_dir($r);
    unlink "$s/.claude.json" or die $!;
    symlink '/etc/passwd', "$s/.claude.json" or die $!;
    my $r2 = run_aye({ root => $r->{root} });
    is $r2->{exit}, 1, '.claude.json as a symlink: exits 1';
    like $r2->{err}, qr/\.claude\.json is a symlink/, 'says why';
    unlink "$s/.claude.json" or die $!;

    unlink "$s/.credentials.json" or die $!;
    mkdir "$s/.credentials.json" or die $!;
    $r2 = run_aye({ root => $r->{root} });
    is $r2->{exit}, 1, 'the credentials mount point as a dir: exits 1';
    like $r2->{err}, qr/\.credentials\.json is not a regular file/, 'says why';
};

done_testing;
