use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

# The forward is opt-in: an agent signature can't be scoped to one destination,
# so a host agent reaches the session only when --allow-ssh says so.

subtest 'host agent present, no flag: not forwarded' => sub {
    my $r = run_aye({ ssh_sock => 1 });
    is $r->{exit}, 0, 'exits 0';
    ok !(grep { m{/run/ssh-agent} } @{$r->{argv}}), 'no socket bind, no setenv';
    unlike $r->{err}, qr/allow-ssh/, 'and no warning';
};

subtest '--allow-ssh forwards the socket at a fixed path' => sub {
    my $r = run_aye({ ssh_sock => 1 }, '--allow-ssh');
    is $r->{exit}, 0;
    my @b = bwrap_binds($r->{argv}, '--bind');
    ok +(grep { $_->[1] eq '/run/ssh-agent' } @b),
        'agent socket bound at /run/ssh-agent';
    my ($src) = map { $_->[0] } grep { $_->[1] eq '/run/ssh-agent' } @b;
    like $src, qr{/agent\.sock\z}, 'from the host socket';

    # --setenv SSH_AUTH_SOCK /run/ssh-agent, not the host-side path.
    my ($i) = grep { $r->{argv}[$_] eq 'SSH_AUTH_SOCK' } 0 .. $#{$r->{argv}};
    ok defined $i, 'SSH_AUTH_SOCK is set in the sandbox';
    is $r->{argv}[$i + 1], '/run/ssh-agent', 'pointing at the fixed path';

    like $r->{err}, qr/--allow-ssh:.*any host/, 'warns about the scope';
};

subtest '--allow-ssh without a host agent says so and continues' => sub {
    my $r = run_aye('--allow-ssh');
    is $r->{exit}, 0, 'still launches';
    ok !(grep { m{/run/ssh-agent} } @{$r->{argv}}), 'nothing forwarded';
    like $r->{err}, qr/no agent socket at SSH_AUTH_SOCK/, 'explains why';
};

done_testing;
