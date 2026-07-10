use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

subtest 'running outside any git/jj repo is rejected' => sub {
    my $r = run_aye({ no_repo => 1 });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/not inside a git or jj repository/, 'says why';
    is $r->{argv}, [], 'bwrap never invoked';
};

done_testing;
