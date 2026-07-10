use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

# The allowlist is host-side policy (it programs the egress filter, not the
# bwrap argv), so we observe it through the AYE_BUDDY_DEBUG dump on stderr.
# run_aye's child inherits our env except PATH/HOME/SSH_AUTH_SOCK, so setting
# it here reaches aye-buddy.
local $ENV{AYE_BUDDY_DEBUG} = 1;

subtest 'builtin allowlist is populated' => sub {
    my $r = run_aye();
    is $r->{exit}, 0, 'exits 0';
    like $r->{err}, qr/egress allowlist:/, 'dumps the allowlist';
    like $r->{err}, qr/\bapi\.anthropic\.com\b/, 'includes the Claude API host';
    like $r->{err}, qr/\bregistry\.npmjs\.org\b/, 'includes a package registry';
    like $r->{err}, qr/\bgithub\.com\b/, 'includes an HTTPS git host';
};

done_testing;
