use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

subtest '--version prints the version and exits 0' => sub {
    my $r = run_aye('--version');
    is $r->{exit}, 0;
    like $r->{out}, qr/\Aaye-buddy [0-9]+\.[0-9]+\n\z/, 'just the version line';
};

subtest '--help prints usage and exits 0' => sub {
    my $r = run_aye('--help');
    is $r->{exit}, 0;
    like $r->{out}, qr/^usage: aye-buddy/m, 'has a usage line';
    like $r->{out}, qr/--allow-host/, 'documents our flags';
    is $r->{err}, '', 'nothing on stderr';
};

subtest 'help/version run before the sandbox is built' => sub {
    my $r = run_aye({ no_repo => 1 }, '--version');
    is $r->{exit}, 0, 'no repo needed';
    # The stub bwrap/pasta dump their argv to stdout; only the version line is
    # there, so neither was reached.
    unlike $r->{out}, qr/--unshare-user/, 'bwrap was never launched';
};

subtest '-- forces --help through to the agent' => sub {
    my $r = run_aye('--', '--help');
    is $r->{exit}, 0;
    ok +(grep { $_ eq '--help' } @{ $r->{argv} }), '--help reaches the payload';
};

subtest '--help after the agent args is a misplaced flag' => sub {
    my $r = run_aye('-p', 'hi', '--help');
    is $r->{exit}, 1;
    like $r->{err}, qr/came after the agent's arguments/;
};

done_testing;
