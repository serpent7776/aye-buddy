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

    # Transcripts hold source and pasted secrets; claude keeps projects/ 0700,
    # so when aye-buddy is the one creating it, it must not be world-readable.
    for my $d ("$env{HOME}/.claude/projects", $projects[0][1], "$env{HOME}/.cache/aye-buddy") {
        is sprintf('%04o', (stat $d)[2] & oct('7777')), '0700', "$d is 0700";
    }
};

# The slug is the project path with dashes, so a deep enough repo has one past
# NAME_MAX and the transcript dir cannot exist. That costs persistence only —
# the sandbox's projects/ is tmpfs — so the run must go ahead without the bind.
subtest 'an uncreatable transcript dir is a warning, not a refusal' => sub {
    my $r = run_aye({ repo_name => join('/', ('d' x 60) x 5) });
    is $r->{exit}, 0, 'still launches';
    like $r->{err}, qr/cannot create the session transcript dir/, 'says so';
    like $r->{err}, qr/will not persist/, 'and what it costs';
    my @rw = (bwrap_binds($r->{argv}, '--bind'), bwrap_binds($r->{argv}, '--bind-try'));
    my @tr = grep { $_->[1] =~ m{/\.claude/projects/} } @rw;
    is scalar(@tr), 1, 'the transcript bind is still requested';
    ok !-e $tr[0][0], 'as bind-try, with no source for it to find';
    ok !(grep { $_->[1] =~ m{/\.claude/projects\z} } @rw), 'and projects/ itself is not bound';
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

# Each of these is loaded by a later host-side claude — as a command it runs,
# or as text it puts in the model's context. The flat files come back read-only;
# the content dirs are overlays whose upper layer is a tmpfs bwrap discards, so
# a write appears to work in-session but never reaches the host.
my @claude_dirs = qw(commands agents skills output-styles plugins hooks scripts);
subtest 'writes to the exec-bearing ~/.claude paths cannot reach the host' => sub {
    my $r = run_aye({ claude_dirs => [@claude_dirs] });
    is $r->{exit}, 0;
    my @a = @{$r->{argv}};
    my $home = setenv_value($r->{argv}, 'HOME');
    my %ro = map { $_->[1] => 1 } bwrap_binds($r->{argv}, '--ro-bind-try');
    ok $ro{"$home/.claude/$_"}, "$_ is ro" for qw(
        settings.json settings.local.json CLAUDE.md
        mcp.json .mcp.json statusline-command.sh
    );
    for my $d (@claude_dirs) {
        my ($i) = grep { $a[$_] eq '--overlay-src' && $a[$_ + 1] eq "$home/.claude/$d" }
                  0 .. $#a - 1;
        ok(defined $i, "$d is an overlay lower layer") or next;
        is [@a[$i + 2 .. $i + 3]], ['--tmp-overlay', "$home/.claude/$d"],
            "$d gets a throwaway upper at the same path";
        ok !$ro{"$home/.claude/$d"}, "$d is not also ro-bound";
    }
};

# --overlay-src aborts bwrap on a missing source, so absent dirs are skipped
# host-side instead — the -try contract, minus the atomicity: the check runs at
# launch, not mount time, and nothing deletes these dirs in between.
subtest 'absent ~/.claude dirs produce no overlay' => sub {
    my $r = run_aye();
    is $r->{exit}, 0;
    my $home = setenv_value($r->{argv}, 'HOME');
    is scalar(grep { m{\A\Q$home\E/\.claude/} } overlay_dests($r->{argv})), 0, 'none requested';
};

# Landlock rules only ever grant — the $HOME-wide rw entry already covers the
# dest, so an ro entry couldn't deny anything — but the lists document intent,
# and a future reshuffle of the broad grants would inherit a stale ro entry.
subtest 'overlay dests go in the rw Landlock list' => sub {
    my $r = run_aye({ claude_dirs => ['skills'] });
    is $r->{exit}, 0;
    my $dest = setenv_value($r->{argv}, 'HOME') . '/.claude/skills';
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
    my $home = setenv_value($r->{argv}, 'HOME');
    my @mounts = grep { $_->[1] eq "$home/.claude/config.json" }
                 map  { bwrap_binds($r->{argv}, $_) }
                 qw(--bind --bind-try --ro-bind --ro-bind-try);
    is scalar(@mounts), 0, 'not mounted under any flag';
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

# Overlayfs mounts directories only, so a plain file at an overlaid name can't
# come back; it used to bind ro, so the skip is called out rather than silent.
subtest 'a non-directory at an overlaid ~/.claude path warns' => sub {
    my $r = run_aye({ claude_files => ['hooks'] });
    is $r->{exit}, 0, 'still launches';
    like $r->{err}, qr/hooks is not a directory/, 'says so';
    my $home = setenv_value($r->{argv}, 'HOME');
    ok !(grep { $_ eq "$home/.claude/hooks" } overlay_dests($r->{argv})), 'and no overlay for it';
};

# The ~/.claude guards mount after the extra binds, so a bind under ~/.claude
# would be silently covered — writes vanishing with the throwaway upper at
# exit — and a bind of an ancestor would put the real ~/.claude back wholesale.
subtest 'an extra bind under ~/.claude is refused' => sub {
    my $r = run_aye({ claude_dirs => ['skills'] }, '--bind', '../home/.claude/skills');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr{overlaps ~/\.claude}, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
};

subtest 'an extra bind of an ancestor of ~/.claude is refused' => sub {
    my $r = run_aye('--bind-ro', '../home');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr{overlaps ~/\.claude}, 'the real ~/.claude would come back';
    is $r->{argv}, [], 'bwrap never invoked';
};

done_testing;
