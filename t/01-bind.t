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

# /etc, not /tmp: the harness home lives under TMPDIR, and a bind of an
# ancestor of ~/.claude is refused.
subtest '--bind=PATH form is accepted' => sub {
    my $r = run_aye('--bind=/etc');
    is $r->{exit}, 0, 'exits 0';
    my @b = bwrap_binds($r->{argv}, '--bind');
    ok +(grep { $_->[0] eq '/etc' && $_->[1] eq '/etc' } @b),
        'exposes /etc rw at the same path';
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
    my $r = run_aye('--bind-ro', '/etc');
    is $r->{exit}, 0;
    my @b = bwrap_binds($r->{argv}, '--ro-bind');
    ok +(grep { $_->[0] eq '/etc' && $_->[1] eq '/etc' } @b),
        'exposes /etc ro at the same path';
};

subtest 'repeated --bind flags all reach bwrap' => sub {
    my $r = run_aye('--bind', '/etc', '--bind', '/usr');
    is $r->{exit}, 0;
    my @b = bwrap_binds($r->{argv}, '--bind');
    ok +(grep { $_->[0] eq '/etc' } @b), '/etc bound';
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
    # Toolchain caches take source and tokens; not for other users to read.
    is sprintf('%04o', (stat $cache->[0])[2] & oct('7777')), '0700', 'created 0700';

    # The toolchains that ignore XDG_CACHE_HOME are pointed at it explicitly.
    my %env = do {
        my @a = @{$r->{argv}};
        map { $a[$_ + 1] => $a[$_ + 2] } grep { $a[$_] eq '--setenv' } 0 .. $#a - 2;
    };
    like $env{npm_config_cache}, qr{/\.cache/npm\z}, 'npm cache redirected';
    like $env{CARGO_HOME},       qr{/\.cache/cargo\z}, 'cargo home redirected';
    like $env{GOPATH},           qr{/\.cache/go\z}, 'GOPATH redirected';
};

# The cache dir is what backs $HOME/.cache in the sandbox, so failing to create
# it stays fatal — but with aye-buddy's message, not a raw File::Path croak.
subtest 'an uncreatable cache dir fails cleanly' => sub {
    my $r = run_aye({ cache_file => 1 });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/\Aaye-buddy: cannot create the sandbox cache dir/, 'our message';
    unlike $r->{err}, qr/File\/Path\.pm|at .* line \d+/, 'no perl croak';
    is $r->{argv}, [], 'bwrap never invoked';
};

# Landlock rules only ever grant — the $HOME-wide rw entry already covers the
# dest, so an ro entry couldn't deny anything — but the lists document intent,
# and a future reshuffle of the broad grants would inherit a stale ro entry.
subtest 'overlay dests go in the rw Landlock list' => sub {
    my $r = run_aye({ repo_claude_dirs => ['worktrees'] });
    is $r->{exit}, 0;
    my ($dest) = grep { m{/repo/\.claude/worktrees\z} } overlay_dests($r->{argv});
    ok(defined $dest, 'the worktrees dir is overlaid') or return;
    my @ro = setenv_list($r->{argv}, 'LL_RO');
    ok(scalar(@ro), 'LL_RO is present') or return;
    ok +(grep { $_ eq $dest } setenv_list($r->{argv}, 'LL_RW')), 'in LL_RW';
    ok !(grep { $_ eq $dest } @ro), 'not in LL_RO';
};

# The overlay options exist since bwrap 0.10; an older one would abort on the
# constructed argv with its own error, so it is refused up front by version.
subtest 'a pre-overlay bwrap is refused' => sub {
    my $r = run_aye({ bwrap_version => 'bubblewrap 0.9.0' });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/bwrap 0\.9 is too old.*0\.10/, 'names the floor';
    is $r->{argv}, [], 'the sandbox is never launched';
};

# The version decides a security-relevant gate, so it comes from the number
# after the bubblewrap banner, not whatever dotted number appears first.
subtest 'the version is read from the bubblewrap token' => sub {
    my $r = run_aye({ bwrap_version => 'bwrap 2023.1 (bubblewrap 0.9.0)' });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/bwrap 0\.9 is too old/, 'the banner number decides, not 2023.1';
};

subtest 'a banner without the bubblewrap token is refused' => sub {
    my $r = run_aye({ bwrap_version => 'something 1.2' });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/cannot parse bwrap --version output/, 'named as a parse failure';
};

# The kernel side of the overlay requirement is a real probe, not a release
# parse, so vendor backports below 5.11 pass on their own merits; a host that
# fails only the overlay run is refused with the capability named, and one
# where the control run fails too is not blamed on overlayfs.
subtest 'a kernel without unprivileged overlayfs is refused' => sub {
    my $r = run_aye({ overlay_probe_status => 1 });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/unprivileged overlayfs/, 'names the capability';
    is $r->{argv}, [], 'the sandbox is never launched';
};

# Lower-layer support depends on the filesystem, so the probe runs against the
# repo; a host where only that fails is told which dir is the problem instead
# of being blamed on the kernel.
subtest 'a filesystem refused as an overlay lower gets its own message' => sub {
    my $r = run_aye({ lower_probe_status => 1 });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/overlayfs lower layer/, 'names the requirement';
    like $r->{err}, qr{/repo}, 'and the dirs probed';
    is $r->{argv}, [], 'the sandbox is never launched';
};

subtest 'a host where bwrap cannot sandbox at all gets its own message' => sub {
    my $r = run_aye({ overlay_probe_status => 1, sandbox_probe_status => 1 });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/cannot create a sandbox/, 'not blamed on overlayfs';
    is $r->{argv}, [], 'the sandbox is never launched';
};

# Digits on the stdout of a failing probe are not a version.
subtest 'a failing bwrap --version is not mined for digits' => sub {
    my $r = run_aye({ bwrap_version => 'error near 1.2', bwrap_version_status => 3 });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/bwrap --version failed \(exited 3\)/, 'reports the exit instead';
};

# The cache bind at ~/.cache comes last, so a state dir under it would be
# covered: the session's state and the token would land in the shared cache
# instead, with nothing to say so.
subtest 'a CLAUDE_CONFIG_DIR under ~/.cache is refused' => sub {
    my $r = run_aye({ config_dir => 'home/.cache/claude' });
    is $r->{exit}, 1;
    like $r->{err}, qr/is under ~\/\.cache/;
    is $r->{argv}, [], 'bwrap never invoked';
};

# The state dir is created when missing; a plain file there is refused up
# front, with one message, rather than by whatever first tries to use it.
subtest 'a CLAUDE_CONFIG_DIR that is not a directory is refused' => sub {
    my $r = run_aye({ claude_files => ['cfg'], config_dir => 'home/.claude/cfg', config_dir_absent => 1 });
    is $r->{exit}, 1;
    like $r->{err}, qr/cfg is not a directory/, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
};

subtest 'a missing CLAUDE_CONFIG_DIR is created' => sub {
    my $r = run_aye({ config_dir => 'cfg', config_dir_absent => 1 });
    is $r->{exit}, 0;
    unlike $r->{err}, qr/warning/, 'without complaint';
    my $cfg = setenv_value($r->{argv}, 'CLAUDE_CONFIG_DIR');
    ok -d $cfg, 'as a directory';
    is sprintf('%04o', (stat $cfg)[2] & oct('7777')), '0700', 'mode 0700';
};

# A relative one is resolved against the cwd by claude and would be a path
# under the project dir here; refusing it is simpler than following that.
subtest 'a relative CLAUDE_CONFIG_DIR is refused' => sub {
    my $r = run_aye({ env => { CLAUDE_CONFIG_DIR => 'cfg' } });
    is $r->{exit}, 1;
    like $r->{err}, qr/CLAUDE_CONFIG_DIR must be an absolute path/;
};

# The project dir is rw wholesale, but its .claude/ loads into the next
# host-side claude run in this repo — same reasoning as the .git/hooks guard.
# Created when missing, or the guard would skip exactly the repos with nothing
# there yet and a session could plant one.
subtest 'the project .claude comes back read-only' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my @a = @{$r->{argv}};
    my ($guard) = grep { $_->[1] =~ m{/repo/\.claude\z} }
                  bwrap_binds($r->{argv}, '--ro-bind');
    ok $guard, 'an --ro-bind covers it';
    is $guard->[0], $guard->[1], 'at the same path inside';
    ok !(grep { m{/repo/\.claude\z} } overlay_dests($r->{argv})), 'not overlaid';
    ok -d "$r->{root}/repo/.claude", 'created on the host when absent';

    # bwrap's last mount on a target wins, so the guard must follow the rw
    # project bind or it protects nothing.
    my ($proj) = grep { $a[$_] eq '--bind' && $a[$_ + 2] =~ m{/repo\z} } 0 .. $#a - 2;
    my ($ro)   = grep { $a[$_] eq '--ro-bind' && $a[$_ + 2] =~ m{/repo/\.claude\z} } 0 .. $#a - 2;
    ok(defined $proj && defined $ro, 'both mounts found') or return;
    ok $ro > $proj, 'mounted after the rw project bind';
};

# git worktree add writes the checkout under .claude/worktrees and its admin dir
# under .git/worktrees; both get throwaway uppers so in-session worktrees work
# whole and are discarded whole — a persistent half would leave the host repo
# with a registered-but-missing worktree.
subtest 'the worktree dirs come back as throwaway overlays' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my @a = @{$r->{argv}};
    my ($ro) = grep { $a[$_] eq '--ro-bind' && $a[$_ + 2] =~ m{/repo/\.claude\z} } 0 .. $#a - 2;
    for my $wt (qw(.claude/worktrees .git/worktrees)) {
        my ($i) = grep { $a[$_] eq '--overlay-src' && $a[$_ + 1] =~ m{/repo/\Q$wt\E\z} } 0 .. $#a - 1;
        ok(defined $i, "$wt is an overlay lower layer") or next;
        is [@a[$i + 2 .. $i + 3]], ['--tmp-overlay', $a[$i + 1]], "$wt gets a throwaway upper at the same path";
        ok -d "$r->{root}/repo/$wt", "$wt created on the host when absent";
        ok $i > $ro, "$wt mounted after the ro .claude guard";
    }
};

# The .claude guard needs a real directory, and skipping it would leave the
# rw project dir free to grow a real .claude/ underneath.
subtest 'a plain file at the project .claude is refused' => sub {
    my $r = run_aye({ repo_claude_file => 1 });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/\.claude is not a directory/, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
};

# A read-only bind follows symlinks, so a .claude pointing elsewhere would mount
# its target into the session instead of guarding the repo's own dir.
subtest 'a symlinked project .claude is refused' => sub {
    my $r = run_aye({ repo_claude_link => 'elsewhere' });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/\.claude is a symlink/, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
};

# The ~/.claude guards mount after the extra binds, so a bind under ~/.claude
# would be silently covered — writes vanishing with the throwaway upper at
# exit — and a bind of an ancestor would put the real ~/.claude back wholesale.
subtest 'an extra bind under ~/.claude is refused' => sub {
    my $r = run_aye({ claude_dirs => ['skills'] }, '--bind', '../home/.claude/skills');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr{overlaps .*/\.claude}, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
};

subtest 'an extra bind of an ancestor of ~/.claude is refused' => sub {
    my $r = run_aye('--bind-ro', '../home');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr{overlaps .*/\.claude}, 'the real ~/.claude would come back';
    is $r->{argv}, [], 'bwrap never invoked';
};

# The project .claude guards mount after the extra binds too, so a bind under
# them would be silently shadowed. Only that direction: under an ancestor bind
# the guards still mount last and win, so binding the project dir stays allowed.
subtest 'an extra bind under the project .claude is refused' => sub {
    my $r = run_aye({ repo_claude_dirs => ['worktrees'] }, '--bind', '.claude/worktrees');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr{under the project's \.claude}, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';

    $r = run_aye('--bind-ro', '.');
    is $r->{exit}, 0, 'but an ancestor bind is not refused';
};

done_testing;
