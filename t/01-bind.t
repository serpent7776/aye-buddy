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

done_testing;
