use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

# Egress filtering is on by default: aye-buddy execs `pasta`, whose argv nests
# `aye-netns-seal ... -- bwrap <args>`. The stub pasta dumps that argv, so we
# assert on the constructed launch. (The real aye-proxy starts on the host to
# hand out a port; it is torn down when the stub pasta exits.)
sub has { my ($r, $tok) = @_; scalar grep { $_ eq $tok } @{$r->{argv}} }

subtest 'default: sandbox runs under pasta with proxy env, no --share-net' => sub {
    my $r = run_aye();
    is $r->{exit}, 0, 'exits 0';
    ok has($r, '--config-net'), 'launched via pasta --config-net';
    ok !has($r, '--ipv4-only'), 'pasta keeps dual-stack; IPv6 is sealed at the routes, not here';
    ok has($r, '--quiet'), 'pasta quieted so its notes stay off the TUI';
    ok has($r, 'bwrap'), 'bwrap nested in the launch chain';
    ok +(grep { m{aye-netns-seal} } @{$r->{argv}}), 'aye-netns-seal in the chain';
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

subtest 'routing tightens by default; --no-lan-filter opts out' => sub {
    my $tight = run_aye();
    ok !has($tight, '--no-lan-filter'),
        'default launch does not pass --no-lan-filter to the helper';

    my $loose = run_aye('--no-lan-filter');
    is $loose->{exit}, 0, 'exits 0';
    ok has($loose, '--no-lan-filter'),
        '--no-lan-filter is forwarded to aye-netns-seal';
    # and it stays an aye-buddy flag, not a claude one
    my @after_claude = do {
        my @a = @{$loose->{argv}};
        my ($ci) = grep { $a[$_] eq 'claude' } 0 .. $#a;
        defined $ci ? @a[$ci .. $#a] : ();
    };
    ok !(grep { $_ eq '--no-lan-filter' } @after_claude),
        '--no-lan-filter does not leak into the claude payload';

    # The `!` spec owns the positive form too, and it's the default. pass_through
    # forwards an unrecognised flag rather than failing, so what proves the spec
    # covers it is that it's consumed here and reaches nothing downstream.
    my $explicit = run_aye('--lan-filter');
    is $explicit->{exit}, 0, '--lan-filter is accepted';
    ok !has($explicit, '--lan-filter'), 'and consumed, not forwarded';
    ok !has($explicit, '--no-lan-filter'), 'and tightens as usual';
};

subtest '--allow-reserved is ours, not claude\'s' => sub {
    # It reaches aye-proxy, which this harness doesn't capture (the proxy is
    # forked, not exec'd through the stub), so assert the parsing half: the flag
    # is accepted and does not end up in the payload claude sees.
    my $r = run_aye('--allow-reserved');
    is $r->{exit}, 0, 'exits 0';
    my @after_claude = do {
        my @a = @{$r->{argv}};
        my ($ci) = grep { $a[$_] eq 'claude' } 0 .. $#a;
        defined $ci ? @a[$ci .. $#a] : ();
    };
    ok !(grep { $_ eq '--allow-reserved' } @after_claude),
        '--allow-reserved does not leak into the claude payload';
};

subtest 'a missing ip is caught up front, and only when filtering' => sub {
    my $r = run_aye({ no_ip => 1 });
    is $r->{exit}, 1, 'refuses to launch';
    like $r->{err}, qr/needs ip \(iproute2\)/, 'names the package, not a route error';

    my $off = run_aye({ no_ip => 1 }, '--no-net-filter');
    is $off->{exit}, 0, '--no-net-filter does not need ip';
};

subtest '--no-net-filter after claude args is a misplaced-flag error' => sub {
    my $r = run_aye('-p', 'hi', '--no-net-filter');
    is $r->{exit}, 1;
    like $r->{err}, qr/aye-buddy flag but came after/;
};

done_testing;
