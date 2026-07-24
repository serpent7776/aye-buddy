use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use POSIX qw(dup2);
use IO::Socket::INET ();

# Drive aye-netns-seal directly — the netns-side script 08-net-filter never
# exercises, only asserts aye-buddy assembles. Root and a real netns aren't
# available here, so `ip`/`nft` are PATH stubs: a stateful stub `ip` that
# records every call and lets `route del default` actually clear the state
# `route show default` reads back (so the egress seal can genuinely pass or
# fail), and a real loopback listener stands in for the reachable proxy.
my $HELPER = abs_path(__FILE__ . '/../../aye-netns-seal')
    or die "cannot locate aye-netns-seal";

# A parked listener == the proxy is reachable; connects land in its backlog
# (never accepted, which is fine — the handshake completes regardless).
my $lsock = IO::Socket::INET->new(Listen => 50, LocalAddr => '127.0.0.1',
    LocalPort => 0, ReuseAddr => 1, Proto => 'tcp') or die "listener: $!";
my $LPORT = $lsock->sockport;

# A port with nothing behind it: connect() refuses immediately == unreachable.
sub dead_port {
    my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0,
        Proto => 'tcp', Listen => 1) or die $!;
    my $p = $s->sockport;
    close $s;
    return $p;
}

sub stub {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "stub $path: $!";
    print $fh "#!$^X\nuse strict; use warnings;\n$body\n";
    close $fh;
    chmod 0755, $path or die "chmod $path: $!";
}

my $IP_STUB = <<'IP';
my @a = @ARGV;
my $st = $ENV{AYE_STATE};
if (open my $log, '>>', "$st/ip.log") { print $log "@a\n"; close $log }
my $fam = '4';
if    (@a && $a[0] eq '-4') { shift @a }
elsif (@a && $a[0] eq '-6') { $fam = '6'; shift @a }
shift @a if @a && $a[0] eq 'route';
my $sub = $a[0] // '';
if ($sub eq 'show' && ($a[1] // '') eq 'default') {
    if (open my $x, '<', "$st/v${fam}default") { local $/; print scalar <$x> }
    exit 0;
}
if ($sub eq 'show') { print $ENV{AYE_LINK} // ''; exit 0 }   # scope link dev IFC
if ($sub eq 'del' && ($a[1] // '') eq 'default') {
    unlink "$st/v${fam}default" unless $ENV{AYE_DEL_NOOP};
    exit 0;
}
if ($sub eq 'get') {
    if ($ENV{AYE_UNSEALED}) { print "$a[1] dev eth0 src 1.2.3.4\n"; exit 0 }
    print STDERR "RTNETLINK answers: Network is unreachable\n"; exit 2;
}
exit 0;   # del PFX / replace / everything else is a recorded no-op
IP

my $NFT_STUB = <<'NFT';
my $st = $ENV{AYE_STATE};
open my $log, '>>', "$st/nft.log" or exit 0;
if (@ARGV >= 2 && $ARGV[0] eq '-f') {
    local $/; my $r = <STDIN> // '';
    print $log "RULESET\n$r";
} else {
    print $log "CMD @ARGV\n";
}
close $log;
exit 0;
NFT

# The exec target: echoes its argv and the proxy env so tests can assert the
# @@AYE_PROXY@@ rewrite and HTTP(S)_PROXY injection reached the child.
my $PROBE_STUB = <<'PROBE';
print "ARG\t$_\n" for @ARGV;
print "ENV\t$_\t", ($ENV{$_} // ''), "\n"
    for qw(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy);
exit 0;
PROBE

# run_helper(\%opts) -> { out, err, exit, ip_log, nft_log }
#   opts: raw_argv (arrayref, verbatim argv — for parse-error tests) OR the
#   built form: seccomp('-'), allow_subnet, port($LPORT), probe_args, and the
#   world knobs gw/ifc/link/no_default/v6def/del_noop/unsealed/no_nft.
sub run_helper {
    my ($o) = @_;
    my $gw  = $o->{gw}  // '127.0.0.1';
    my $ifc = $o->{ifc} // 'aye0';

    my $root  = tempdir(CLEANUP => 1);
    my $bin   = "$root/bin";
    my $state = "$root/state";
    make_path($bin, $state);
    stub("$bin/ip", $IP_STUB);
    stub("$bin/nft", $NFT_STUB) unless $o->{no_nft};
    stub("$bin/probe", $PROBE_STUB);

    unless ($o->{no_default}) {
        open my $f, '>', "$state/v4default" or die $!;
        print $f "default via $gw dev $ifc\n";
        close $f;
    }
    if ($o->{v6def}) {
        open my $f, '>', "$state/v6default" or die $!;
        print $f "default via fe80::1 dev $ifc\n";
        close $f;
    }

    my @argv = $o->{raw_argv} ? @{$o->{raw_argv}} : (
        $o->{port} // $LPORT,
        $o->{seccomp} // '-',
        ($o->{allow_subnet} ? ('--allow-subnet') : ()),
        '--', "$bin/probe", @{$o->{probe_args} // ['@@AYE_PROXY@@']},
    );

    my ($outf, $errf) = ("$root/out", "$root/err");
    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        $ENV{PATH}      = $bin;
        $ENV{AYE_STATE} = $state;
        $ENV{AYE_GW}    = $gw;
        $ENV{AYE_IFC}   = $ifc;
        $ENV{AYE_LINK}  = $o->{link} // "10.0.2.0/24 dev $ifc proto kernel scope link\n";
        $ENV{AYE_DEL_NOOP} = 1 if $o->{del_noop};
        $ENV{AYE_UNSEALED} = 1 if $o->{unsealed};
        delete $ENV{$_} for qw(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy);
        chdir $root or die "chdir: $!";
        open my $out, '>', $outf or die $!;
        open my $err, '>', $errf or die $!;
        dup2(fileno($out), 1) or die $!;
        dup2(fileno($err), 2) or die $!;
        exec { $^X } $^X, $HELPER, @argv;
        die "exec helper: $!";
    }
    waitpid $pid, 0;
    my $exit = $? >> 8;

    my $slurp = sub { open my $fh, '<', $_[0] or return ''; local $/; scalar <$fh> };
    return {
        out     => $slurp->($outf),
        err     => $slurp->($errf),
        exit    => $exit,
        ip_log  => $slurp->("$state/ip.log"),
        nft_log => $slurp->("$state/nft.log"),
    };
}

# --- argv parsing: these die before any `ip` call, so they need no world ------

subtest 'usage errors are reported and exit 1 before touching the network' => sub {
    my $none = run_helper({ raw_argv => [] });
    is $none->{exit}, 1, 'no args exits 1';
    like $none->{err}, qr/usage/, 'prints usage';
    is $none->{ip_log}, '', 'no ip commands ran';

    like run_helper({ raw_argv => ['8080'] })->{err}, qr/missing SECCOMP/,
        'a port with no seccomp arg is rejected';
    like run_helper({ raw_argv => ['8080', '-', 'true'] })->{err},
        qr/expected -- separator/, 'a missing -- separator is rejected';
    like run_helper({ raw_argv => ['8080', '-', '--'] })->{err},
        qr/no command to exec/, 'a -- with no command is rejected';

    like run_helper({ raw_argv => ['nope', '-', '--', 'true'] })->{err},
        qr/not a valid TCP port/, 'a non-numeric port is rejected';
    like run_helper({ raw_argv => ['0', '-', '--', 'true'] })->{err},
        qr/not a valid TCP port/, 'port 0 is rejected';
    like run_helper({ raw_argv => ['70000', '-', '--', 'true'] })->{err},
        qr/not a valid TCP port/, 'an out-of-range port is rejected';
};

subtest 'a netns with no default route refuses to launch' => sub {
    my $r = run_helper({ no_default => 1 });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/no default route present/, 'names the missing route';
};

# --- default (sealed) launch --------------------------------------------------

subtest 'default launch: seal holds, routing tightens, proxy is injected' => sub {
    my $r = run_helper({});
    is $r->{exit}, 0, 'execs the target';

    like $r->{ip_log}, qr/^route del default$/m, 'drops the IPv4 default route';
    like $r->{ip_log}, qr{^route replace 127\.0\.0\.1/32 dev aye0$}m,
        'pins a host-route to the gateway';
    like $r->{ip_log}, qr{^route del 10\.0\.2\.0/24 dev aye0$}m,
        'removes the on-link subnet route (LAN loses its path)';

    my $url = "http://127.0.0.1:$LPORT";
    like $r->{out}, qr/^ARG\t\Q$url\E$/m, '@@AYE_PROXY@@ rewritten to the proxy URL';
    unlike $r->{out}, qr/\@\@AYE_PROXY\@\@/, 'no placeholder survives into the argv';
    like $r->{out}, qr/^ENV\tHTTP_PROXY\t\Q$url\E$/m,  'HTTP_PROXY exported';
    like $r->{out}, qr/^ENV\thttps_proxy\t\Q$url\E$/m, 'lowercase https_proxy exported';

    like $r->{nft_log}, qr/ip daddr 127\.0\.0\.1 tcp dport $LPORT accept/,
        'nft allows only the proxy port on the gateway';
    like $r->{nft_log}, qr/meta nfproto ipv6 drop/, 'nft drops all IPv6 egress';
};

subtest 'a surviving IPv6 default route is dropped too' => sub {
    my $r = run_helper({ v6def => 1 });
    is $r->{exit}, 0, 'still launches';
    like $r->{ip_log}, qr/^-6 route del default$/m, 'the IPv6 default is deleted';
};

# --- --allow-subnet -----------------------------------------------------------

subtest '--allow-subnet keeps the on-link route but still seals the internet' => sub {
    my $r = run_helper({ allow_subnet => 1 });
    is $r->{exit}, 0, 'launches';
    like $r->{ip_log}, qr/^route del default$/m, 'the internet default is still dropped';
    unlike $r->{ip_log}, qr{route replace 127\.0\.0\.1/32},
        'no gateway-only tightening';
    unlike $r->{ip_log}, qr{route del 10\.0\.2\.0/24 dev},
        'the on-link subnet route is left in place';
};

# --- the egress seal is the fail-closed backstop ------------------------------

subtest 'a surviving default route fails the seal and refuses to launch' => sub {
    my $r = run_helper({ del_noop => 1 });   # `route del default` is a no-op
    is $r->{exit}, 1, 'refuses to launch';
    like $r->{err}, qr/egress seal unverified/, 'reports the unverified seal';
    like $r->{err}, qr/--no-net-filter/, 'points at the escape hatch';
    is $r->{out}, '', 'the target never ran';
};

subtest 'a narrow nexthop route the probe misses still fails the seal' => sub {
    my $r = run_helper({ link => "8.8.8.0/24 via 10.0.2.1 dev aye0\n" });
    is $r->{exit}, 1, 'refuses to launch';
    like $r->{err}, qr/egress seal unverified/, 'the via-scan arm catches it';
};

subtest 'a concrete route to the probe address also fails the seal' => sub {
    # default is gone, but `route get` still resolves a route out -> not sealed.
    my $r = run_helper({ unsealed => 1 });
    is $r->{exit}, 1, 'refuses to launch';
    like $r->{err}, qr/egress seal unverified/, 'the get-probe arm catches it';
};

# --- non-fatal degradations: reachability and nft are best-effort -------------

subtest 'gateway unreachable after tightening restores the subnet route' => sub {
    my $r = run_helper({ port => dead_port() });   # nothing answers the proxy port
    is $r->{exit}, 0, 'the seal holds independently, so it still launches';
    like $r->{err}, qr/gateway unreachable after tightening/, 'warns about reachability';
    like $r->{err}, qr/restoring the on-link subnet route/, 'restores rather than opening up';
    like $r->{ip_log}, qr{^route replace 10\.0\.2\.0/24 dev aye0$}m,
        'the subnet route is put back';
    like $r->{err}, qr/proxy unreachable after loopback hardening/,
        'nft hardening backs itself out when it breaks the proxy';
    like $r->{nft_log}, qr/CMD delete table inet aye_egress/, 'the nft table is removed';
};

subtest 'missing nft degrades to a warning, not a failed launch' => sub {
    my $r = run_helper({ no_nft => 1 });
    is $r->{exit}, 0, 'still launches — nft is secondary hardening';
    like $r->{err}, qr/host-loopback and IPv6 side channels stay reachable/,
        'warns the side channels remain open';
    like $r->{err}, qr/internet route seal still holds/, 'but the primary seal is intact';
};

done_testing;
