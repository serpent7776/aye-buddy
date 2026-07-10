use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

sub payload {
    my ($argv) = @_;
    for my $i (0 .. $#$argv) {
        return @{$argv}[$i .. $#$argv] if $argv->[$i] eq 'claude';
    }
    return ();
}

subtest 'plain claude args are forwarded verbatim' => sub {
    my $r = run_aye('-p', 'hello world');
    is $r->{exit}, 0;
    my @p = payload($r->{argv});
    # aye-buddy injects its own flags first, then our args.
    ok +(grep { $_ eq '--dangerously-skip-permissions' } @p), 'skip-perms present';
    my ($pi) = grep { $p[$_] eq '-p' } 0 .. $#p;
    ok defined $pi, '-p forwarded';
    is $p[$pi + 1], 'hello world', 'value kept intact';
};

# The no_auto_abbrev / no_ignore_case guarantees: near-misses must NOT trigger
# our flags; they fall through to claude untouched.
my @near_misses = (
    ['--allo',          'abbrev of --allow-bwrap'],
    ['--allow-bwrapx',  'trailing junk'],
    ['--ALLOW-BWRAP',   'wrong case'],
    ['--bind-rox',      'trailing junk on --bind-ro'],
    ['--all',           'unrelated claude-ish flag'],
);

for my $case (@near_misses) {
    my ($flag, $desc) = @$case;
    subtest "near-miss $flag ($desc) is not our flag" => sub {
        my $r = run_aye($flag);
        is $r->{exit}, 0, 'not rejected as misplaced';
        unlike $r->{err}, qr/isolation is reduced/, 'did not enable --allow-bwrap';
        my @p = payload($r->{argv});
        ok +(grep { $_ eq $flag } @p), 'forwarded to claude verbatim';
    };
}

done_testing;
