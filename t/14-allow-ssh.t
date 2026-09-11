use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

# The forward is opt-in: an agent signature can't be scoped to one destination,
# so a host agent reaches the session only when --allow-ssh says so. The ssh
# config (~/.ssh/config, known_hosts) rides along with the flag: no agent, no
# reason for the session to see which hosts and keys the user has.

sub ssh_config_binds {
    my ($argv) = @_;
    grep { $_->[1] =~ m{/\.ssh/(?:config|known_hosts)\z} } bwrap_binds($argv, '--ro-bind-try');
}

subtest 'host agent present, no flag: not forwarded' => sub {
    my $r = run_aye({ ssh_sock => 1 });
    is $r->{exit}, 0, 'exits 0';
    ok !(grep { m{/run/ssh-agent} } @{$r->{argv}}), 'no socket bind, no setenv';
    unlike $r->{err}, qr/allow-ssh/, 'and no warning';
    is [ssh_config_binds($r->{argv})], [], 'ssh config not mounted either';
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

    is [ sort map { $_->[1] } ssh_config_binds($r->{argv}) ],
       [ map { "$r->{root}/home/.ssh/$_" } qw(config known_hosts) ],
       'ssh config and known_hosts mounted ro';
};

subtest '--allow-ssh without a host agent says so and continues' => sub {
    my $r = run_aye('--allow-ssh');
    is $r->{exit}, 0, 'still launches';
    ok !(grep { m{/run/ssh-agent} } @{$r->{argv}}), 'nothing forwarded';
    like $r->{err}, qr/no agent socket at SSH_AUTH_SOCK/, 'explains why';
    is [ sort map { $_->[1] } ssh_config_binds($r->{argv}) ],
       [ map { "$r->{root}/home/.ssh/$_" } qw(config known_hosts) ],
       'ssh config still mounted: the flag was given';
};

done_testing;
