use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

subtest 'bare --bind with no PATH is rejected' => sub {
    my $r = run_aye('--bind');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/--bind requires a PATH argument/, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
};

subtest 'bare --bind-ro with no PATH is rejected' => sub {
    my $r = run_aye('--bind-ro');
    is $r->{exit}, 1;
    like $r->{err}, qr/--bind-ro requires a PATH argument/;
};

subtest '--bind=PATH form is accepted' => sub {
    my $r = run_aye('--bind=/tmp');
    is $r->{exit}, 0, 'exits 0';
    my @b = bwrap_binds($r->{argv}, '--bind');
    ok +(grep { $_->[0] eq '/tmp' && $_->[1] eq '/tmp' } @b),
        'exposes /tmp rw at the same path';
};

# Two rejection branches: a missing leaf under a real dir still resolves (abs_path
# returns a path), so -e catches it as "no such path"; a missing intermediate
# makes abs_path return undef, caught earlier as "cannot resolve path".
subtest 'missing leaf under a real dir: no such path' => sub {
    my $r = run_aye('--bind', '/tmp/aye-buddy-does-not-exist-leaf');
    is $r->{exit}, 1;
    like $r->{err}, qr/no such path/;
};

subtest 'missing intermediate dir: cannot resolve path' => sub {
    my $r = run_aye('--bind', '/no/such/path/here');
    is $r->{exit}, 1;
    like $r->{err}, qr/cannot resolve path/;
};

# The rejected value is echoed back, so a path can't smuggle terminal escapes
# into the message (a directory name is not always something the user typed).
subtest 'a control byte in a rejected path is not echoed raw' => sub {
    my $r = run_aye('--bind', "/no/such\e[2Kpath");
    is $r->{exit}, 1;
    unlike $r->{err}, qr/\e/, 'no escape byte on the terminal';
    like $r->{err}, qr{\Q/no/such?[2Kpath\E}, 'replaced, rest of the path intact';
};

# U+009B is CSI: a terminal decodes it from UTF-8 and acts on it as `ESC [`,
# so scrubbing the 7-bit escapes alone would leave the same sequence usable.
subtest 'the 8-bit form of a control byte is scrubbed too' => sub {
    my $r = run_aye('--bind', "/no/such\xc2\x9b2Kpath");
    is $r->{exit}, 1;
    unlike $r->{err}, qr/\x9b/, 'no CSI on the terminal';
    like $r->{err}, qr{\Q/no/such??2Kpath\E}, 'both bytes of it replaced';
};

# A newline would split the newline-joined LL_RW/LL_RO lists, silently dropping
# the real path's Landlock grant, so it's rejected outright.
subtest 'newline in --bind path is rejected' => sub {
    my $r = run_aye('--bind', "/tmp\n/etc");
    is $r->{exit}, 1;
    like $r->{err}, qr/may not contain a newline/;
    is $r->{argv}, [], 'bwrap never invoked';
};

subtest 'relative --bind path is resolved to absolute' => sub {
    # The harness runs inside a temp repo; '.' resolves to that repo dir, which
    # exists, so this must succeed and reach bwrap as an absolute path.
    my $r = run_aye('--bind', '.');
    is $r->{exit}, 0;
    my @b = bwrap_binds($r->{argv}, '--bind');
    ok +(grep { $_->[0] =~ m{^/} && $_->[0] eq $_->[1] } @b),
        'a resolved absolute rw bind is present';
};

subtest '--bind-ro uses bwrap --ro-bind' => sub {
    my $r = run_aye('--bind-ro', '/tmp');
    is $r->{exit}, 0;
    my @b = bwrap_binds($r->{argv}, '--ro-bind');
    ok +(grep { $_->[0] eq '/tmp' && $_->[1] eq '/tmp' } @b),
        'exposes /tmp ro at the same path';
};

subtest 'repeated --bind flags all reach bwrap' => sub {
    my $r = run_aye('--bind', '/tmp', '--bind', '/usr');
    is $r->{exit}, 0;
    my @b = bwrap_binds($r->{argv}, '--bind');
    ok +(grep { $_->[0] eq '/tmp' } @b), '/tmp bound';
    ok +(grep { $_->[0] eq '/usr' } @b), '/usr bound';
};

subtest 'caches persist in our own dir, not the host ones' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my @b = bwrap_binds($r->{argv}, '--bind');
    my ($cache) = grep { $_->[1] =~ m{/\.cache\z} } @b;
    ok $cache, 'something is mounted at $HOME/.cache';
    like $cache->[0], qr{/\.cache/aye-buddy\z}, 'backed by our own subdir';
    isnt $cache->[0], $cache->[1], 'the host ~/.cache itself is not the source';

    # The toolchains that ignore XDG_CACHE_HOME are pointed at it explicitly.
    my %env = do {
        my @a = @{$r->{argv}};
        map { $a[$_ + 1] => $a[$_ + 2] } grep { $a[$_] eq '--setenv' } 0 .. $#a - 2;
    };
    like $env{npm_config_cache}, qr{/\.cache/npm\z}, 'npm cache redirected';
    like $env{CARGO_HOME},       qr{/\.cache/cargo\z}, 'cargo home redirected';
    like $env{GOPATH},           qr{/\.cache/go\z}, 'GOPATH redirected';
};

# ~/.claude is an allowlist, not a rw bind with ro patches over it: nothing under
# it exists in the sandbox unless it is named. A regression here is invisible at
# runtime (claude works fine either way) and hands a session the host's config
# dir, so assert the shape rather than the individual entries.
subtest '~/.claude is not bound wholesale' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my @rw = (bwrap_binds($r->{argv}, '--bind'), bwrap_binds($r->{argv}, '--bind-try'));
    ok !(grep { $_->[1] =~ m{/\.claude\z} } @rw),
        'no rw bind of the ~/.claude dir itself';

    my %env = do {
        my @a = @{$r->{argv}};
        map { $a[$_ + 1] => $a[$_ + 2] } grep { $a[$_] eq '--setenv' } 0 .. $#a - 2;
    };
    my ($project) = map { $_->[1] } grep { $_->[1] eq $_->[0] && $_->[1] =~ m{/repo\z} } @rw;
    ok $project, 'the project dir is bound rw';

    # Only this project's transcript dir comes back, under claude's own naming.
    my @projects = grep { $_->[1] =~ m{/\.claude/projects/} } @rw;
    is scalar(@projects), 1, 'exactly one transcript dir is writable';
    like $projects[0][1], qr{\A\Q$env{HOME}/.claude/projects/\E-.*-repo\z},
        'and it is this project\'s';
};

# The slug rule belongs to claude, so pin the name a known directory has to
# produce. Deriving the expectation with the implementation's own regex would
# follow any future change to it, including a wrong one.
subtest 'the transcript dir name follows claude\'s slug rule' => sub {
    my $r = run_aye({ repo_name => 'My Proj..v2_x' });
    is $r->{exit}, 0;
    my @rw = (bwrap_binds($r->{argv}, '--bind'), bwrap_binds($r->{argv}, '--bind-try'));
    my ($projects) = grep { $_->[1] =~ m{/\.claude/projects/} } @rw;
    ok $projects, 'a transcript dir is bound';

    my ($slug) = $projects->[1] =~ m{/\.claude/projects/(.+)\z};
    like $slug, qr/\A-/, 'the leading separator becomes a dash';
    like $slug, qr/\Q-My-Proj--v2-x\E\z/,
        'one dash per non-alphanumeric, runs kept, case preserved';
};

subtest 'the exec-bearing ~/.claude paths come back read-only' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my %ro = map { $_->[1] => 1 } bwrap_binds($r->{argv}, '--ro-bind-try');
    my ($home) = map { $r->{argv}[$_ + 2] }
                 grep { $r->{argv}[$_] eq '--setenv' && $r->{argv}[$_ + 1] eq 'HOME' }
                 0 .. $#{$r->{argv}} - 2;
    # Each of these is loaded by a later host-side claude — as a command it runs,
    # or as text it puts in the model's context.
    ok $ro{"$home/.claude/$_"}, "$_ is ro" for qw(
        settings.json settings.local.json CLAUDE.md
        commands agents skills output-styles plugins hooks scripts
        mcp.json .mcp.json statusline-command.sh
    );

};

# A bind needs its source to exist, and an OAuth login in-session writes through
# it to the host inode — so an absent credentials file is created, not skipped.
# Losing this silently means logging in again on every run.
subtest 'the credentials file is created and bound rw' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my $creds = "$r->{root}/home/.claude/.credentials.json";
    ok -e $creds, 'created on the host when absent';
    my @st = stat $creds;
    is $st[7], 0, 'empty, so claude reads it back as logged out';
    is sprintf('%04o', $st[2] & oct('7777')), '0600',
        'and not readable by other users';

    my @rw = bwrap_binds($r->{argv}, '--bind');
    ok +(grep { $_->[0] eq $creds && $_->[1] eq $creds } @rw),
        'bound rw at the same path';
};

# config.json is a stale copy of credentials claude no longer reads, so no run
# has a reason to mount it.
subtest 'config.json stays out of the session' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my ($home) = map { $r->{argv}[$_ + 2] }
                 grep { $r->{argv}[$_] eq '--setenv' && $r->{argv}[$_ + 1] eq 'HOME' }
                 0 .. $#{$r->{argv}} - 2;
    my @mounts = grep { $_->[1] eq "$home/.claude/config.json" }
                 map  { bwrap_binds($r->{argv}, $_) }
                 qw(--bind --bind-try --ro-bind --ro-bind-try);
    is scalar(@mounts), 0, 'not mounted under any flag';
};

done_testing;
