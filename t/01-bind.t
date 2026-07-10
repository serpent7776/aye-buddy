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

done_testing;
