use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

# --clearenv wipes the environment, so a kept var is visible as a --setenv pair
# in the argv aye-buddy hands bwrap. run_aye's child inherits our env except
# PATH/HOME/SSH_AUTH_SOCK, so setting a var here reaches aye-buddy.

subtest 'a host var is cleared without the flag' => sub {
    local $ENV{AYE_TEST_VAR} = 'secret';
    my $r = run_aye();
    is $r->{exit}, 0, 'exits 0';
    is setenv_value($r->{argv}, 'AYE_TEST_VAR'), undef, 'never reaches the sandbox';
};

subtest '--keep-env carries the var through' => sub {
    local $ENV{AYE_TEST_VAR} = 'kept';
    my $r = run_aye('--keep-env', 'AYE_TEST_VAR');
    is $r->{exit}, 0;
    is setenv_value($r->{argv}, 'AYE_TEST_VAR'), 'kept', 'with its host value';
    is $r->{err}, '', 'quietly';
};

subtest '--keep-env=NAME form is accepted' => sub {
    local $ENV{AYE_TEST_VAR} = 'kept';
    my $r = run_aye('--keep-env=AYE_TEST_VAR');
    is $r->{exit}, 0;
    is setenv_value($r->{argv}, 'AYE_TEST_VAR'), 'kept';
};

subtest 'repeated --keep-env flags all apply' => sub {
    local $ENV{AYE_TEST_ONE} = '1';
    local $ENV{AYE_TEST_TWO} = '2';
    my $r = run_aye('--keep-env', 'AYE_TEST_ONE', '--keep-env', 'AYE_TEST_TWO');
    is $r->{exit}, 0;
    is setenv_value($r->{argv}, 'AYE_TEST_ONE'), '1';
    is setenv_value($r->{argv}, 'AYE_TEST_TWO'), '2';
};

subtest 'a repeated name is emitted once' => sub {
    local $ENV{AYE_TEST_VAR} = 'kept';
    my $r = run_aye('--keep-env', 'AYE_TEST_VAR', '--keep-env', 'AYE_TEST_VAR');
    is $r->{exit}, 0;
    my @hits = grep { $r->{argv}[$_] eq '--setenv' && $r->{argv}[$_ + 1] eq 'AYE_TEST_VAR' }
               0 .. $#{$r->{argv}} - 2;
    is scalar @hits, 1, 'one --setenv pair';
};

subtest 'an empty value is kept as empty, not dropped' => sub {
    local $ENV{AYE_TEST_VAR} = '';
    my $r = run_aye('--keep-env', 'AYE_TEST_VAR');
    is $r->{exit}, 0;
    is setenv_value($r->{argv}, 'AYE_TEST_VAR'), '', 'set but empty';
};

subtest 'an unset var says so and the session still launches' => sub {
    delete local $ENV{AYE_TEST_MISSING};
    my $r = run_aye('--keep-env', 'AYE_TEST_MISSING');
    is $r->{exit}, 0, 'still launches';
    is setenv_value($r->{argv}, 'AYE_TEST_MISSING'), undef, 'nothing kept';
    like $r->{err}, qr/AYE_TEST_MISSING is not set/, 'explains why';
};

subtest 'bare --keep-env with no NAME is rejected' => sub {
    my $r = run_aye('--keep-env');
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/--keep-env requires a NAME argument/, 'explains why';
    is $r->{argv}, [], 'bwrap never invoked';
};

subtest 'NAME=VALUE and other junk names are rejected' => sub {
    for my $name ('FOO=bar', '2FOO', 'FOO-BAR', 'FOO BAR', 'foo.bar') {
        my $r = run_aye('--keep-env', $name);
        is $r->{exit}, 1, "$name is refused";
        like $r->{err}, qr/invalid variable name/, "$name says why";
    }
};

subtest "names aye-buddy manages itself are refused" => sub {
    # Keeping one would either lose to ours or break the layer it belongs to.
    for my $name (qw(HOME PATH LL_RW LL_STRICT HTTPS_PROXY no_proxy CARGO_HOME
                     XDG_CACHE_HOME SSH_AUTH_SOCK CLAUDE_CODE_SANDBOXED)) {
        local $ENV{$name} = 'x';
        my $r = run_aye('--keep-env', $name);
        is $r->{exit}, 1, "$name is refused";
        like $r->{err}, qr/\Q$name\E is part of aye-buddy's own setup/, "$name says why";
    }
};

subtest 'a proxy var is keepable once the egress filter is off' => sub {
    # With filtering on these point at the bundled proxy and are ours; with
    # --no-net-filter aye-buddy sets none, so the host's is the session's only
    # way to name a proxy.
    local $ENV{HTTPS_PROXY} = 'http://corp.proxy:3128';
    local $ENV{no_proxy}    = 'internal.corp';
    my $r = run_aye('--no-net-filter', '--keep-env', 'HTTPS_PROXY',
                                       '--keep-env', 'no_proxy');
    is $r->{exit}, 0, 'accepted';
    is setenv_value($r->{argv}, 'HTTPS_PROXY'), 'http://corp.proxy:3128';
    is setenv_value($r->{argv}, 'no_proxy'), 'internal.corp', 'bypass list too';
};

subtest 'a loader search path is refused' => sub {
    # aye-landlock is a perl script that runs before the agent: one of these
    # pointing into the (writable) project would get code run ahead of the
    # ruleset, which could then exec the agent with no ruleset at all.
    for my $name (qw(PERL5LIB PERLLIB PERL5OPT LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH)) {
        # PERL5OPT holds switches, and the perl running aye-buddy reads it too.
        local $ENV{$name} = $name eq 'PERL5OPT' ? '-Mstrict' : '/some/lib';
        my $r = run_aye('--keep-env', $name);
        is $r->{exit}, 1, "$name is refused";
        like $r->{err}, qr/\Q$name\E is part of aye-buddy's own setup/, "$name says why";
        is $r->{argv}, [], "$name never reaches bwrap";
    }
};

subtest 'a loader search path is refused with Landlock already off' => sub {
    # --allow-bwrap drops Landlock, so the ruleset argument is moot there — but
    # the flag still isn't a way to preload into aye-buddy's own helpers.
    local $ENV{LD_PRELOAD} = '/some/lib.so';
    my $r = run_aye('--allow-bwrap', '--keep-env', 'LD_PRELOAD');
    is $r->{exit}, 1, 'still refused';
    like $r->{err}, qr/can't be kept/;
};

subtest 'a value equal to a helper placeholder is kept verbatim' => sub {
    # Both rewrites are anchored to the flag they belong to, so a value that
    # happens to match a placeholder is just a value.
    for my $token ('@@AYE_SECCOMP_FD@@', '@@AYE_PROXY@@') {
        local $ENV{AYE_TEST_VAR} = $token;
        my $r = run_aye('--keep-env', 'AYE_TEST_VAR');
        is $r->{exit}, 0, "$token launches";
        is setenv_value($r->{argv}, 'AYE_TEST_VAR'), $token, "$token survives intact";
    }
};

subtest 'a forwarded var keeps its host value' => sub {
    local $ENV{TERM} = 'screen-256color';
    my $r = run_aye('--keep-env', 'TERM');
    is $r->{exit}, 0;
    is setenv_value($r->{argv}, 'TERM'), 'screen-256color', 'host TERM wins';
};

subtest 'keeping an unset forwarded var leaves the fallback in place' => sub {
    delete local $ENV{TERM};
    my $r = run_aye('--keep-env', 'TERM');
    is $r->{exit}, 0;
    is setenv_value($r->{argv}, 'TERM'), 'xterm', 'aye-buddy fallback survives';
    like $r->{err}, qr/TERM is not set/, 'and says nothing was kept';
};

subtest '--keep-env after claude args is a misplaced-flag error' => sub {
    my $r = run_aye('-p', 'hi', '--keep-env', 'AYE_TEST_VAR');
    is $r->{exit}, 1;
    like $r->{err}, qr/aye-buddy flag but came after/, 'flagged as misplaced';
};

subtest '--keep-env after `--` reaches claude untouched' => sub {
    local $ENV{AYE_TEST_VAR} = 'kept';
    my $r = run_aye('--', '--keep-env', 'AYE_TEST_VAR');
    is $r->{exit}, 0, 'exits 0';
    is setenv_value($r->{argv}, 'AYE_TEST_VAR'), undef, 'not kept by aye-buddy';
    ok +(grep { $_ eq '--keep-env' } @{ $r->{argv} }), 'forwarded to the payload';
};

done_testing;
