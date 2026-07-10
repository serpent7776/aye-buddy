use strict;
use warnings;
use Test2::V0;
use IO::Socket::INET;
use Cwd qw(abs_path);

# aye-proxy is testable without a sandbox: it's just a loopback CONNECT proxy,
# so we exercise its allow/deny decisions directly. No bwrap, no netns needed.
my $PROXY = abs_path('aye-proxy') or die "cannot locate aye-proxy";

my @kids;
sub reap { kill 'TERM', @kids; waitpid $_, 0 for @kids; }

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

# Start aye-proxy with the given allow entries; return its listening port.
sub start_proxy {
    my @allow = @_;
    pipe(my $rd, my $wr) or die "pipe: $!";
    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        close $rd;
        open STDOUT, '>&', $wr or die;
        exec $^X, $PROXY, map { ('--allow', $_) } @allow;
        die "exec proxy: $!";
    }
    push @kids, $pid;
    close $wr;
    my $line = <$rd>;
    my ($port) = ($line // '') =~ /port=(\d+)/
        or do { reap(); die "no port from proxy (got: " . ($line // 'eof') . ")" };
    return $port;
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

subtest 'non-allowlisted host is refused' => sub {
    my $pport = start_proxy("127.0.0.1:$origin");
    my ($s, $status) = connect_via($pport, "10.255.255.1:443");
    like $status, qr{^HTTP/1\.1 403 }, 'blocked by allowlist';
    close $s;
};

subtest 'allowlisted host on a non-permitted port is refused' => sub {
    # Port-less entry permits only 80/443, so the ephemeral origin port is denied.
    my $pport = start_proxy("127.0.0.1");
    my ($s, $status) = connect_via($pport, "127.0.0.1:$origin");
    like $status, qr{^HTTP/1\.1 403 }, 'port not permitted';
    close $s;
};

subtest 'non-CONNECT method is rejected' => sub {
    my $pport = start_proxy("127.0.0.1:$origin");
    my $s = IO::Socket::INET->new(PeerHost => '127.0.0.1', PeerPort => $pport,
        Proto => 'tcp') or die $!;
    $s->autoflush(1);
    print $s "GET http://127.0.0.1/ HTTP/1.1\r\nHost: x\r\n\r\n";
    like scalar(<$s>), qr{^HTTP/1\.1 405 }, 'plain HTTP not served';
    close $s;
};

reap();
done_testing;
