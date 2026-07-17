use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

# --seccomp rides on an inherited fd (the number is spliced in at exec time),
# but which blob is opened is chosen by --allow-bwrap. We can't see the fd from
# the argv, so we assert on the observable consequences instead: the warnings
# and the payload wrapper.

subtest 'default run: no --allow-bwrap warning' => sub {
    my $r = run_aye();
    is $r->{exit}, 0, 'exits 0';
    unlike $r->{err}, qr/allow-bwrap/, 'no nested-sandbox warning';
};

subtest '--allow-bwrap warns that isolation is reduced' => sub {
    my $r = run_aye('--allow-bwrap');
    is $r->{exit}, 0;
    like $r->{err}, qr/isolation is reduced/, 'loud about the trade-off';
};

subtest '--allow-bwrap disables Landlock (payload not perl-wrapped)' => sub {
    my $plain   = run_aye();
    my $relaxed = run_aye('--allow-bwrap');

    # With Landlock on, the payload is `perl <ll_dest> -- claude ...`.
    # With --allow-bwrap, Landlock is dropped, so claude is invoked directly.
    ok +(grep { m{aye-buddy-ll-helper} } @{$plain->{argv}}),
        'default: ll-helper wraps the payload';
    ok !(grep { m{aye-buddy-ll-helper} } @{$relaxed->{argv}}),
        '--allow-bwrap: no ll-helper wrapper';

    # Either way the LL_RW/LL_RO env is only set when Landlock is on.
    ok +(grep { $_ eq 'LL_RW' } @{$plain->{argv}}),   'default sets LL_RW';
    ok !(grep { $_ eq 'LL_RW' } @{$relaxed->{argv}}), '--allow-bwrap omits LL_RW';
};

done_testing;
