use strict;
use warnings;
use Test2::V0;
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_RCVTIMEO);
use Fcntl qw(F_SETFD);
use Cwd qw(abs_path);
use Time::HiRes qw(sleep);

# Bound blocking reads on $s, so a tunnel that swallows bytes fails the test
# instead of hanging the suite. Done at the socket, not with select(): buffered
# readline can already hold data the socket itself no longer reports as ready.
sub set_read_timeout {
    my ($s, $secs) = @_;
    setsockopt($s, SOL_SOCKET, SO_RCVTIMEO, pack('l!l!', $secs, 0))
        or die "SO_RCVTIMEO: $!";
    return;
}

# aye-proxy is testable without a sandbox: it's just a loopback CONNECT proxy,
# so we exercise its allow/deny decisions directly. No bwrap, no netns needed.
my $PROXY = abs_path('aye-proxy') or die "cannot locate aye-proxy";

my @kids;
sub reap { kill 'TERM', @kids; waitpid $_, 0 for @kids; }

# Direct children of $ppid, read from /proc (Linux-only, like the rest of the
# sandbox). Used to catch tunnel handlers the proxy forks per connection.
sub child_pids_of {
    my ($ppid) = @_;
    my @out;
    opendir(my $d, '/proc') or return @out;
    for my $pid (grep { /\A[0-9]+\z/ } readdir $d) {
        open(my $fh, '<', "/proc/$pid/stat") or next;
        my $stat = readline($fh);
        # Drop "pid (comm) state " so the next field is the ppid; comm can hold
        # spaces and parens, so match through the last ')'.
        next unless defined $stat && $stat =~ s/\A[0-9]+\s+\(.*\)\s+\S+\s+//s;
        my ($pp) = split ' ', $stat;
        push @out, $pid if defined $pp && $pp == $ppid;
    }
    return @out;
}

# A stub origin: greets with HELLO, then echoes one line back as ECHO:<line>.
sub start_origin {
    my $srv = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1',
        LocalPort => 0, ReuseAddr => 1, Proto => 'tcp') or die "origin: $!";
    my $port = $srv->sockport;
    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        while (my $c = $srv->accept) {
            $c->autoflush(1);
            print $c "HELLO\n";
            my $l = <$c>;
            print $c "ECHO:$l" if defined $l;
            close $c;
        }
        exit 0;
    }
    push @kids, $pid;
    return $port;
}

sub listener {
    return IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1',
        LocalPort => 0, ReuseAddr => 1, Proto => 'tcp') // die "listen: $!";
}

# Start aye-proxy on an already-listening socket via --fd, the way aye-buddy's
# supervisor does.
sub start_proxy_on_fd {
    my ($srv, @allow) = @_;
    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';    # keep the proxy's DENY warns out of prove
        fcntl($srv, F_SETFD, 0) or die "F_SETFD: $!";
        exec $^X, $PROXY, '--fd', fileno($srv), map { ('--allow', $_) } @allow;
        die "exec proxy: $!";
    }
    push @kids, $pid;
    return $pid;
}

# Start aye-proxy with the given allow entries; return its listening port.
# Clients need not wait for the proxy to come up: the socket is bound before
# the fork, so early connections queue in the backlog.
sub start_proxy {
    my @allow = @_;
    my $srv = listener();
    start_proxy_on_fd($srv, @allow);
    return $srv->sockport;
}

# Open a CONNECT request through the proxy; return (socket, status_line).
sub connect_via {
    my ($pport, $target) = @_;
    my $s = IO::Socket::INET->new(PeerHost => '127.0.0.1', PeerPort => $pport,
        Proto => 'tcp') or die "dial proxy: $!";
    $s->autoflush(1);
    print $s "CONNECT $target HTTP/1.1\r\nHost: $target\r\n\r\n";
    my $status = <$s>;
    return ($s, $status // '');
}

my $origin = start_origin();

subtest 'allowlisted host:port tunnels through' => sub {
    my $pport = start_proxy("127.0.0.1:$origin");
    my ($s, $status) = connect_via($pport, "127.0.0.1:$origin");
    like $status, qr{^HTTP/1\.1 200 }, 'CONNECT established';
    my $blank = <$s>;    # consume the header terminator
    is <$s>, "HELLO\n", 'origin banner reaches the client';
    print $s "PING\n";
    is <$s>, "ECHO:PING\n", 'bytes flow back through the tunnel';
    close $s;
};

subtest 'bytes pipelined behind the CONNECT reach the origin' => sub {
    # A client that doesn't wait for the 200 lands its first payload in the same
    # read as the request line. Those bytes belong to the tunnel, not the header:
    # dropping them strands the peer waiting for a handshake that never arrives.
    my $pport = start_proxy("127.0.0.1:$origin");
    my $s = IO::Socket::INET->new(PeerHost => '127.0.0.1', PeerPort => $pport,
        Proto => 'tcp') or die "dial proxy: $!";
    $s->autoflush(1);
    set_read_timeout($s, 5);
    print $s "CONNECT 127.0.0.1:$origin HTTP/1.1\r\nHost: x\r\n\r\nPING\n";
    like scalar(<$s>), qr{^HTTP/1\.1 200 }, 'CONNECT established';
    my $blank = <$s>;    # consume the header terminator
    is <$s>, "HELLO\n", 'origin banner reaches the client';
    is <$s>, "ECHO:PING\n", 'the pipelined line was forwarded';
    close $s;
};

subtest 'non-allowlisted host is refused' => sub {
    my $pport = start_proxy("127.0.0.1:$origin");
    my ($s, $status) = connect_via($pport, "10.255.255.1:443");
    like $status, qr{^HTTP/1\.1 403 }, 'blocked by allowlist';
    close $s;
};

subtest 'a subdomain of an allowlisted host is refused' => sub {
    # Host match is exact. Under a dot-suffix rule this would tunnel, handing
    # the destination to whoever can create a record under the allowed domain.
    my $pport = start_proxy("localhost:$origin");
    my ($s, $status) = connect_via($pport, "sub.localhost:$origin");
    like $status, qr{^HTTP/1\.1 403 }, 'subdomain not covered by the parent';
    close $s;
};

subtest 'an allowlisted hostname tunnels through' => sub {
    my $pport = start_proxy("localhost:$origin");
    my ($s, $status) = connect_via($pport, "localhost:$origin");
    like $status, qr{^HTTP/1\.1 200 }, 'exact hostname match allowed';
    close $s;
};

subtest 'a dotted entry covers the domain and its subdomains' => sub {
    my $pport = start_proxy(".localhost:$origin");
    my ($s, $status) = connect_via($pport, "localhost:$origin");
    like $status, qr{^HTTP/1\.1 200 }, 'the domain itself is allowed too';
    close $s;
    # Whether sub.localhost resolves is the resolver's business, so accept
    # either outcome past the allow decision: 200 dialled, 502 didn't resolve.
    my ($s2, $status2) = connect_via($pport, "sub.localhost:$origin");
    like $status2, qr{^HTTP/1\.1 (200|502) }, 'subdomain cleared the allowlist';
    close $s2;
};

subtest 'a dotted entry still needs the dot boundary' => sub {
    my $pport = start_proxy(".localhost:$origin");
    my ($s, $status) = connect_via($pport, "notlocalhost:$origin");
    like $status, qr{^HTTP/1\.1 403 }, 'a bare suffix is not a subdomain';
    close $s;
};

subtest 'allowlisted host on a non-permitted port is refused' => sub {
    # Port-less entry permits only 443, so the ephemeral origin port is denied.
    my $pport = start_proxy("127.0.0.1");
    my ($s, $status) = connect_via($pport, "127.0.0.1:$origin");
    like $status, qr{^HTTP/1\.1 403 }, 'port not permitted';
    close $s;
};

subtest 'a port-less entry does not imply port 80' => sub {
    # The proxy serves CONNECT only, so :80 granted an unadvertised raw-TCP lane
    # to every allowlisted host without making http:// work. Ask for it by name.
    my $pport = start_proxy("127.0.0.1");
    my ($s, $status) = connect_via($pport, "127.0.0.1:80");
    like $status, qr{^HTTP/1\.1 403 }, 'port 80 is not implied';
    close $s;
};

subtest 'non-CONNECT method is rejected' => sub {
    my $pport = start_proxy("127.0.0.1:$origin");
    my $s = IO::Socket::INET->new(PeerHost => '127.0.0.1', PeerPort => $pport,
        Proto => 'tcp') or die $!;
    $s->autoflush(1);
    print $s "GET http://127.0.0.1/ HTTP/1.1\r\nHost: x\r\n\r\n";
    like scalar(<$s>), qr{^HTTP/1\.1 405 }, 'plain HTTP not served';
    # The body is the only place the reason shows up; an empty 405 leaves the
    # caller guessing why an http:// URL failed.
    my $rest = do { local $/; <$s> };
    like $rest, qr/CONNECT only/, '405 explains itself';
    close $s;
};

subtest 'connection cap sheds load past the limit' => sub {
    # Cap at one live tunnel; the second concurrent connection must be refused
    # rather than fork an unbounded number of host processes.
    local $ENV{AYE_PROXY_MAX_CONNS} = 1;
    my $pport = start_proxy("127.0.0.1:$origin");

    my ($s1, $st1) = connect_via($pport, "127.0.0.1:$origin");
    like $st1, qr{^HTTP/1\.1 200 }, 'first tunnel established';
    my $blank = <$s1>;                 # header terminator
    is <$s1>, "HELLO\n", 'first tunnel is live (child holds a slot)';

    my ($s2, $st2) = connect_via($pport, "127.0.0.1:$origin");
    like $st2, qr{^HTTP/1\.1 503 }, 'second connection shed at the cap';

    close $s2;
    close $s1;
};

subtest 'a client that connects while no proxy is attached is served after one attaches' => sub {
    # The restart-gap property: the launcher holds the listening socket, so a
    # connection landing between one proxy and the next queues in the backlog
    # instead of being refused, and completes once the replacement accepts.
    my $srv = listener();
    my $s = IO::Socket::INET->new(PeerHost => '127.0.0.1',
        PeerPort => $srv->sockport, Proto => 'tcp') or die "dial: $!";
    $s->autoflush(1);
    set_read_timeout($s, 5);
    print $s "CONNECT 127.0.0.1:$origin HTTP/1.1\r\nHost: x\r\n\r\n";
    start_proxy_on_fd($srv, "127.0.0.1:$origin");
    like scalar(<$s>), qr{^HTTP/1\.1 200 }, 'queued connection completes';
    my $blank = <$s>;    # consume the header terminator
    is <$s>, "HELLO\n", 'tunnel is live';
    close $s;
};

subtest 'tunnel children do not outlive a proxy shutdown' => sub {
    # A live tunnel is handled by a forked grandchild. Killing the proxy parent
    # must take that child down too, not orphan it to init still holding egress.
    my $pport = start_proxy("127.0.0.1:$origin");
    my $ppid  = $kids[-1];

    # Establish a tunnel and leave it open: the origin blocks reading our line,
    # so the handler stays in pump() rather than exiting on EOF.
    my ($s, $status) = connect_via($pport, "127.0.0.1:$origin");
    like $status, qr{^HTTP/1\.1 200 }, 'tunnel established';
    my $blank = <$s>;
    is <$s>, "HELLO\n", 'tunnel is live';

    my @tunnel = child_pids_of($ppid);
    is scalar(@tunnel), 1, 'proxy forked one tunnel handler';

    kill 'TERM', $ppid;
    waitpid $ppid, 0;
    pop @kids;    # reaped here; keep the final reap() from waiting on it again

    # The handler is not our child, so poll liveness instead of waitpid.
    my $alive = 1;
    for (1 .. 40) { last unless $alive = kill 0, $tunnel[0]; sleep 0.05 }
    ok !$alive, 'tunnel handler died with the proxy';
    close $s;
};

reap();
done_testing;
