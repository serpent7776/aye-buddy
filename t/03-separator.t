use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

# Pull the claude payload (everything from the literal 'claude' token onward) out
# of the captured bwrap argv, so we can assert on what claude actually receives.
sub payload {
    my ($argv) = @_;
    for my $i (0 .. $#$argv) {
        return @{$argv}[$i .. $#$argv] if $argv->[$i] eq 'claude';
    }
    return ();
}

subtest 'misplaced --allow-bwrap after claude args fails loudly' => sub {
    my $r = run_aye('-p', 'hi', '--allow-bwrap');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/came after the agent's arguments/, 'points at the fix';
};

subtest 'misplaced --bind after claude args fails loudly' => sub {
    my $r = run_aye('-p', 'hi', '--bind');
    is $r->{exit}, 1;
    like $r->{err}, qr/came after the agent's arguments/;
};

subtest '-- forces a literal --allow-bwrap through to claude' => sub {
    my $r = run_aye('--', '--allow-bwrap');
    is $r->{exit}, 0, 'exits 0';
    my @p = payload($r->{argv});
    ok +(grep { $_ eq '--allow-bwrap' } @p), 'reaches the claude payload';
    unlike $r->{err}, qr/isolation is reduced/, 'not treated as our flag';
};

subtest '-- forces a literal --bind through to claude' => sub {
    my $r = run_aye('--', '--bind', '/tmp');
    is $r->{exit}, 0;
    my @p = payload($r->{argv});
    ok +(grep { $_ eq '--bind' } @p), '--bind forwarded verbatim';
};

subtest 'our flags before -- are still consumed' => sub {
    my $r = run_aye('--allow-bwrap', '--', 'ignored');
    is $r->{exit}, 0;
    like $r->{err}, qr/isolation is reduced/, '--allow-bwrap before -- is ours';
};

done_testing;
