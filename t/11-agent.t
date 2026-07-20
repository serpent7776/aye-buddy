use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

# The agent token (default 'claude') opens the payload in the captured argv.
sub payload {
    my ($argv, $bin) = @_;
    for my $i (0 .. $#$argv) {
        return @{$argv}[$i .. $#$argv] if $argv->[$i] eq $bin;
    }
    return ();
}

subtest 'default agent is claude' => sub {
    my $r = run_aye('-p', 'hi');
    is $r->{exit}, 0;
    my @p = payload($r->{argv}, 'claude');
    ok +(grep { $_ eq '--dangerously-skip-permissions' } @p), 'claude payload built';
};

subtest '--agent claude is accepted explicitly' => sub {
    my $r = run_aye('--agent', 'claude', '-p', 'hi');
    is $r->{exit}, 0;
    my @p = payload($r->{argv}, 'claude');
    ok +(grep { $_ eq '-p' } @p), 'args still forwarded';
};

subtest 'unknown agent fails loudly' => sub {
    my $r = run_aye('--agent', 'codex');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/unknown agent: codex/, 'names the bad agent';
    like $r->{err}, qr/supported: claude/, 'lists what is supported';
};

subtest '--agent after the agent args is a misplaced flag' => sub {
    my $r = run_aye('-p', 'hi', '--agent');
    is $r->{exit}, 1;
    like $r->{err}, qr/came after the agent's arguments/;
};

subtest '-- forces a literal --agent through to the agent' => sub {
    my $r = run_aye('--', '--agent', 'codex');
    is $r->{exit}, 0, 'not treated as our flag';
    my @p = payload($r->{argv}, 'claude');
    ok +(grep { $_ eq '--agent' } @p), '--agent reaches the payload';
};

done_testing;
