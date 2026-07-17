use strict;
use warnings;
use Test2::V0;
use FindBin ();
use lib "$FindBin::RealBin/lib";   # AyeTest
use lib "$FindBin::RealBin/..";    # AyeSeccomp, at the repo root
use AyeTest;
use AyeSeccomp qw(arm_seccomp SECCOMP_FD_TOKEN);
use Fcntl qw(F_GETFD FD_CLOEXEC);

# The seccomp blob rides on an inherited fd. aye-buddy bakes a placeholder into
# the bwrap argv; whichever process execs bwrap (aye-buddy directly, or
# aye-net-helper under pasta) arms the blob and rewrites the token to its own fd.
# Both scripts share the arm_seccomp/SECCOMP_FD_TOKEN implementation here.

# The value following a flag in a captured argv.
sub after { my ($argv, $flag) = @_; for my $i (0 .. $#$argv) { return $argv->[$i + 1] if $argv->[$i] eq $flag } undef }

subtest 'arm_seccomp: splices the fd into the argv and clears close-on-exec' => sub {
    my $blob = "$FindBin::RealBin/../filter.bpf";
    my @argv = ('--seccomp', SECCOMP_FD_TOKEN, '--other');
    my $fh = arm_seccomp(\@argv, $blob);
    like $argv[1], qr/^\d+$/, 'placeholder replaced with a numeric fd';
    is $argv[1], fileno($fh), 'the spliced fd is the open handle';
    is $argv[2], '--other', 'other argv entries untouched';
    my $flags = fcntl($fh, F_GETFD, 0);
    is $flags & FD_CLOEXEC, 0, 'FD_CLOEXEC cleared so the fd survives exec';

    like dies { arm_seccomp([], "$$-no-such.bpf") }, qr/open seccomp blob/,
        'a missing blob dies with a clear message';
};

subtest 'token is the documented placeholder' => sub {
    is SECCOMP_FD_TOKEN, '@@AYE_SECCOMP_FD@@', 'stable across both scripts';
};

subtest '--no-net-filter: aye-buddy arms the blob and splices a real fd' => sub {
    my $r = run_aye('--no-net-filter');
    is $r->{exit}, 0, 'exits 0';
    like after($r->{argv}, '--seccomp'), qr/^\d+$/,
        'placeholder replaced with a real fd number before exec';
    ok !(grep { $_ eq SECCOMP_FD_TOKEN } @{$r->{argv}}), 'no placeholder left behind';
};

subtest 'default: placeholder rides through to aye-net-helper' => sub {
    my $r = run_aye();
    is $r->{exit}, 0, 'exits 0';
    is after($r->{argv}, '--seccomp'), SECCOMP_FD_TOKEN,
        'aye-buddy leaves the token for the netns-side helper to arm';
    ok +(grep { m{aye-net-helper} } @{$r->{argv}}), 'helper is in the chain to do it';
};

done_testing;
