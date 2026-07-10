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
    ok has($r, '--ipv4-only'), 'IPv6 disabled so it cannot bypass the IPv4 filter';
    ok has($r, '--quiet'), 'pasta quieted so its notes stay off the TUI';
    ok has($r, 'bwrap'), 'bwrap nested in the launch chain';
    ok +(grep { m{aye-net-helper} } @{$r->{argv}}), 'aye-net-helper in the chain';
    ok has($r, '@@AYE_PROXY@@'), 'proxy URL placeholder is set for the helper';
    ok has($r, '--uid'), 'sandbox uid pinned to the real user (not pasta uid 0)';
    my ($i) = grep { $r->{argv}[$_] eq '--uid' } 0 .. $#{$r->{argv}};
    ok defined $i && ($r->{argv}[$i + 1] // '') =~ /^\d+$/, '--uid carries a numeric value';
    ok !has($r, 'IS_SANDBOX'), 'no root escape hatch — claude sees a normal uid';
    ok !has($r, '--share-net'), 'host network is NOT shared under filtering';
    ok has($r, 'DISABLE_TELEMETRY'), 'telemetry disabled at the source';
};

subtest '--no-net-filter: exec bwrap directly and share the host network' => sub {
    my $r = run_aye('--no-net-filter');
    is $r->{exit}, 0, 'exits 0';
    ok has($r, '--share-net'), 'shares the host network';
    ok !has($r, '--config-net'), 'no pasta wrapper';
    ok !has($r, '@@AYE_PROXY@@'), 'no proxy env injected';
    ok !has($r, '--uid'), 'no uid override (bwrap maps the real uid directly)';
};

subtest 'routing tightens by default; --allow-subnet opts out' => sub {
    my $tight = run_aye();
    ok !has($tight, '--allow-subnet'),
        'default launch does not pass --allow-subnet to the helper';

    my $loose = run_aye('--allow-subnet');
    is $loose->{exit}, 0, 'exits 0';
    ok has($loose, '--allow-subnet'),
        '--allow-subnet is forwarded to aye-net-helper';
    # and it stays an aye-buddy flag, not a claude one
    my @after_claude = do {
        my @a = @{$loose->{argv}};
        my ($ci) = grep { $a[$_] eq 'claude' } 0 .. $#a;
        defined $ci ? @a[$ci .. $#a] : ();
    };
    ok !(grep { $_ eq '--allow-subnet' } @after_claude),
        '--allow-subnet does not leak into the claude payload';
};

subtest '--no-net-filter after claude args is a misplaced-flag error' => sub {
    my $r = run_aye('-p', 'hi', '--no-net-filter');
    is $r->{exit}, 1;
    like $r->{err}, qr/aye-buddy flag but came after/;
};

done_testing;
