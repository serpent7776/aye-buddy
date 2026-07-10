use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

# Egress filtering is on by default: aye-buddy execs `pasta`, whose argv nests
# `aye-net-helper ... -- bwrap <args>`. The stub pasta dumps that argv, so we
# assert on the constructed launch. (The real aye-proxy starts on the host to
# hand out a port; it is torn down when the stub pasta exits.)
sub has { my ($r, $tok) = @_; scalar grep { $_ eq $tok } @{$r->{argv}} }

subtest 'default: sandbox runs under pasta with proxy env, no --share-net' => sub {
    my $r = run_aye();
    is $r->{exit}, 0, 'exits 0';
    ok has($r, '--config-net'), 'launched via pasta --config-net';
    ok has($r, 'bwrap'), 'bwrap nested in the launch chain';
    ok +(grep { m{aye-net-helper} } @{$r->{argv}}), 'aye-net-helper in the chain';
    ok has($r, '@@AYE_PROXY@@'), 'proxy URL placeholder is set for the helper';
    ok !has($r, '--share-net'), 'host network is NOT shared under filtering';
};

subtest '--no-net-filter: exec bwrap directly and share the host network' => sub {
    my $r = run_aye('--no-net-filter');
    is $r->{exit}, 0, 'exits 0';
    ok has($r, '--share-net'), 'shares the host network';
    ok !has($r, '--config-net'), 'no pasta wrapper';
    ok !has($r, '@@AYE_PROXY@@'), 'no proxy env injected';
};

subtest '--no-net-filter after claude args is a misplaced-flag error' => sub {
    my $r = run_aye('-p', 'hi', '--no-net-filter');
    is $r->{exit}, 1;
    like $r->{err}, qr/aye-buddy flag but came after/;
};

done_testing;
