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

subtest '--allow-host adds to the allowlist' => sub {
    my $r = run_aye('--allow-host', 'git.internal.corp:2222');
    is $r->{exit}, 0, 'exits 0';
    like $r->{err}, qr/\bapi\.anthropic\.com\b/, 'defaults still present';
    like $r->{err}, qr/\Qgit.internal.corp:2222\E/, 'extra host present';
};

subtest '--allow-host=HOST form is accepted' => sub {
    my $r = run_aye('--allow-host=example.com');
    is $r->{exit}, 0;
    like $r->{err}, qr/\bexample\.com\b/;
};

subtest 'repeated --allow-host flags all apply' => sub {
    my $r = run_aye('--allow-host', 'a.example', '--allow-host', 'b.example');
    is $r->{exit}, 0;
    like $r->{err}, qr/\ba\.example\b/;
    like $r->{err}, qr/\bb\.example\b/;
};

subtest 'bare --allow-host with no HOST is rejected' => sub {
    my $r = run_aye('--allow-host');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/--allow-host requires a HOST argument/, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
};

subtest 'invalid --allow-host value is rejected' => sub {
    my $r = run_aye('--allow-host', 'http://nope/');
    is $r->{exit}, 1;
    like $r->{err}, qr/invalid host/;
};

subtest 'wildcard --allow-host is rejected' => sub {
    my $r = run_aye('--allow-host', '*.example.com');
    is $r->{exit}, 1;
    like $r->{err}, qr/invalid host/;
};

subtest '--allow-host after claude args is a misplaced-flag error' => sub {
    my $r = run_aye('-p', 'hi', '--allow-host', 'x.example');
    is $r->{exit}, 1;
    like $r->{err}, qr/aye-buddy flag but came after/, 'flagged as misplaced';
};

subtest '--allow-host after `--` reaches claude untouched' => sub {
    my $r = run_aye('--', '--allow-host', 'x.example');
    is $r->{exit}, 0, 'exits 0';
    # After the separator it is a claude arg, so it must NOT extend our list.
    unlike $r->{err}, qr/\bx\.example\b/, 'not added to the egress allowlist';
};

done_testing;
