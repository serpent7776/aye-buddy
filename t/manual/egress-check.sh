#!/usr/bin/env bash
# egress-check.sh — verify the Tier-3 egress mechanism on a real machine.
#
# This is NOT run by `make test`: it needs unprivileged user+net namespaces,
# which don't exist in every CI/sandbox. It drives the SAME artifacts aye-buddy
# ships — aye-proxy (allowlist) and aye-netns-seal (route restriction inside
# pasta's netns) — WITHOUT bwrap, so a failure points at the plumbing, not the
# file sandbox.
#
# Two modes are exercised:
#   default (tight)   — only the proxy is reachable; internet AND same-subnet
#                       (LAN) hosts have no route.
#   --allow-subnet    — the fallback: internet still blocked, but same-subnet
#                       hosts stay reachable.
# In both, an allowlisted host must reach the proxy, a non-allowlisted host must
# get a 403, and raw off-subnet egress (reverse-shell path) must be blocked.
#
# Usage:  t/manual/egress-check.sh
# Needs:  pasta, curl, ip, nft, timeout, perl, and aye-proxy + aye-netns-seal.
set -u

here=$(cd "$(dirname "$0")/../.." && pwd)
proxy_bin="$here/aye-proxy"
netns_seal="$here/aye-netns-seal"

ALLOWED_HOST=${ALLOWED_HOST:-example.com}      # on the allowlist
DENIED_HOST=${DENIED_HOST:-cloudflare.com}     # deliberately not
BLOCKHOLE_IP=${BLOCKHOLE_IP:-1.1.1.1}          # off-subnet raw-egress probe
BLOCKHOLE_V6=${BLOCKHOLE_V6:-2606:4700:4700::1111}  # IPv6 raw-egress probe

command -v pasta  >/dev/null || { echo "SKIP: pasta not installed"; exit 2; }
command -v curl   >/dev/null || { echo "SKIP: curl not installed";  exit 2; }
[ -x "$proxy_bin" ]          || { echo "SKIP: $proxy_bin not found"; exit 2; }
[ -f "$netns_seal" ]         || { echo "SKIP: $netns_seal not found"; exit 2; }

# Start aye-proxy on the host (it has real network; the netns will not).
# It takes its listening socket by fd, so bind here, announce the port, exec.
proxy_out=$(mktemp)
perl -MIO::Socket::INET -MFcntl=F_SETFD -e '
    my ($proxy, $allow) = @ARGV;
    my $srv = IO::Socket::INET->new(Listen => 128, LocalAddr => "127.0.0.1",
        LocalPort => 0, ReuseAddr => 1, Proto => "tcp") or die "listen: $!\n";
    $| = 1;
    print "port=", $srv->sockport, "\n";
    fcntl($srv, F_SETFD, 0) or die "fcntl: $!\n";
    exec $^X, $proxy, "--fd", fileno($srv), "--allow", $allow
        or die "exec: $!\n";
' "$proxy_bin" "$ALLOWED_HOST" >"$proxy_out" 2>"$proxy_out.err" &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null; rm -f "$proxy_out" "$proxy_out.err"' EXIT

for _ in $(seq 1 50); do grep -q '^port=' "$proxy_out" && break; sleep 0.1; done
PROXY_PORT=$(sed -n 's/^port=//p' "$proxy_out")
[ -n "$PROXY_PORT" ] || { echo "FAIL: proxy did not report a port"; cat "$proxy_out.err"; exit 1; }
echo "proxy listening on 127.0.0.1:$PROXY_PORT (allow: $ALLOWED_HOST)"

# A decoy host-loopback service, standing in for a local DB / dashboard on
# 127.0.0.1. pasta maps the gateway to host loopback for every port, so without
# the nft loopback filter the sandbox could reach this at gateway:DECOY_PORT.
# With the filter, only the proxy port gets through — that's the M1 assertion.
decoy_out=$(mktemp)
perl -MIO::Socket::INET -e '
    $| = 1;
    my $s = IO::Socket::INET->new(Listen => 16, LocalAddr => "127.0.0.1",
        LocalPort => 0, ReuseAddr => 1) or die "decoy listen: $!";
    print "port=", $s->sockport, "\n";
    while (my $c = $s->accept) { close $c }
' >"$decoy_out" 2>&1 &
decoy_pid=$!
trap 'kill "$proxy_pid" "$decoy_pid" 2>/dev/null; rm -f "$proxy_out" "$proxy_out.err" "$decoy_out"' EXIT
for _ in $(seq 1 50); do grep -q '^port=' "$decoy_out" && break; sleep 0.1; done
DECOY_PORT=$(sed -n 's/^port=//p' "$decoy_out")
[ -n "$DECOY_PORT" ] || { echo "FAIL: decoy did not report a port"; cat "$decoy_out"; exit 1; }
echo "decoy host-loopback service on 127.0.0.1:$DECOY_PORT (must stay unreachable)"

# Assertions run inside the namespace. aye-netns-seal (spawned by pasta) has
# already restricted the route and exported HTTP(S)_PROXY; here we just probe.
# EXPECT_LAN ("blocked"/"reachable") is the mode-specific expectation for a
# same-subnet host. Vars flow through pasta -> helper -> bash.
export ALLOWED_HOST DENIED_HOST BLOCKHOLE_IP BLOCKHOLE_V6 DECOY_PORT
inner='
set -u
P="$HTTP_PROXY"
gw=$(printf "%s" "$P" | sed -E "s#^http://([^:]+):.*#\1#")
lan="${gw%.*}.254"   # same /24, a different host (avoid sed: $# is a bash param)
echo "--- ns routes ---"; ip -4 route show
rc=0

code=$(timeout 15 curl -sS -o /dev/null -w "%{http_code}" -x "$P" "https://$ALLOWED_HOST/" 2>/dev/null || echo 000)
if [ "$code" -ge 200 ] && [ "$code" -lt 500 ] && [ "$code" != 403 ]; then
    echo "PASS  allowlisted $ALLOWED_HOST reachable via proxy (HTTP $code)"
else echo "FAIL  allowlisted $ALLOWED_HOST via proxy got HTTP $code"; rc=1; fi

code=$(timeout 15 curl -sS -o /dev/null -w "%{http_connect}" -x "$P" "https://$DENIED_HOST/" 2>/dev/null); code=${code:-000}
if [ "$code" = 403 ]; then echo "PASS  non-allowlisted $DENIED_HOST refused (403)"
else echo "FAIL  non-allowlisted $DENIED_HOST got CONNECT $code (want 403)"; rc=1; fi

if timeout 6 curl -sS --noproxy "*" -o /dev/null "https://$BLOCKHOLE_IP/" 2>/dev/null; then
    echo "FAIL  raw egress to $BLOCKHOLE_IP succeeded — reverse shell would work"; rc=1
else echo "PASS  raw egress to $BLOCKHOLE_IP blocked (no route)"; fi

if timeout 6 bash -c "exec 3<>/dev/tcp/$BLOCKHOLE_IP/443" 2>/dev/null; then
    echo "FAIL  /dev/tcp to $BLOCKHOLE_IP:443 connected"; rc=1
else echo "PASS  /dev/tcp reverse-shell primitive blocked"; fi

# IPv6 egress: sealed at the routes (v6 default dropped) AND by the nft v6 drop,
# so no v6 path out — not to the internet, and not to the host-loopback mapping.
if timeout 6 curl -6 -sS --noproxy "*" -o /dev/null "https://[$BLOCKHOLE_V6]/" 2>/dev/null; then
    echo "FAIL  IPv6 raw egress to $BLOCKHOLE_V6 succeeded — v6 side channel open"; rc=1
else echo "PASS  IPv6 raw egress to $BLOCKHOLE_V6 blocked"; fi

# Host-loopback side channel (M1): the gateway maps to the host loopback, so the
# decoy service must NOT be reachable at gw:DECOY_PORT — only the proxy port is.
if timeout 6 bash -c "exec 3<>/dev/tcp/$gw/$DECOY_PORT" 2>/dev/null; then
    echo "FAIL  host-loopback decoy reachable at $gw:$DECOY_PORT — M1 side channel open"; rc=1
else echo "PASS  host-loopback decoy at $gw:$DECOY_PORT blocked (nft loopback filter)"; fi

# Same-subnet host: does the kernel have a route to it?
if ip -4 route get "$lan" >/dev/null 2>&1; then lan_state=reachable; else lan_state=blocked; fi
if [ "$lan_state" = "$EXPECT_LAN" ]; then
    echo "PASS  same-subnet $lan is $lan_state (expected for this mode)"
else echo "FAIL  same-subnet $lan is $lan_state, expected $EXPECT_LAN"; rc=1; fi

exit $rc
'

status=0

echo; echo "=== mode: tight (default) — only the proxy is reachable ==="
EXPECT_LAN=blocked pasta --config-net -- \
    "$netns_seal" "$PROXY_PORT" - -- bash -c "$inner" || status=1

echo; echo "=== mode: --allow-subnet — LAN stays reachable (fallback) ==="
EXPECT_LAN=reachable pasta --config-net -- \
    "$netns_seal" "$PROXY_PORT" - --allow-subnet -- bash -c "$inner" || status=1

echo
if [ "$status" -eq 0 ]; then
    echo "RESULT: egress mechanism verified — tight mode blocks the LAN, --allow-subnet keeps it."
else
    echo "RESULT: FAILED (exit $status). If only the tight-mode LAN check failed, aye-netns-seal"
    echo "        may have auto-reverted (look for its warning above) — the /32 gateway route"
    echo "        did not hold on this host; --allow-subnet is the fallback."
fi
exit "$status"
