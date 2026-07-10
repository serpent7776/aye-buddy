#!/usr/bin/env bash
# egress-check.sh — verify the Tier-3 egress mechanism on a real machine.
#
# This is NOT run by `make test`: it needs unprivileged user+net namespaces,
# which don't exist in every CI/sandbox. It isolates just the network plumbing
# aye-buddy will use — pasta (uplink) + aye-proxy (allowlist) + a route that
# leaves the proxy as the only reachable destination — WITHOUT bwrap, so a
# failure points at the mechanism, not the file sandbox.
#
# It proves the property the whole feature rests on:
#   1. an allowlisted host is reachable *through the proxy*
#   2. a non-allowlisted host is refused (403) by the proxy
#   3. anything NOT going through the proxy has no route out — i.e. a raw-socket
#      reverse shell to an arbitrary IP cannot connect
#
# Usage:  t/manual/egress-check.sh
# Needs:  pasta, curl, ip, timeout, and the aye-proxy next to this repo.
set -u

here=$(cd "$(dirname "$0")/../.." && pwd)
proxy_bin="$here/aye-proxy"

ALLOWED_HOST=${ALLOWED_HOST:-example.com}      # on the allowlist
DENIED_HOST=${DENIED_HOST:-cloudflare.com}     # deliberately not
BLOCKHOLE_IP=${BLOCKHOLE_IP:-1.1.1.1}          # raw-egress probe target

command -v pasta  >/dev/null || { echo "SKIP: pasta not installed"; exit 2; }
command -v curl   >/dev/null || { echo "SKIP: curl not installed";  exit 2; }
[ -x "$proxy_bin" ]          || { echo "SKIP: $proxy_bin not found"; exit 2; }

# 1. Start aye-proxy on the host (it has real network; the netns will not).
#    It prints "port=N" once bound; capture that.
proxy_out=$(mktemp)
"$proxy_bin" --allow "$ALLOWED_HOST" --port 0 >"$proxy_out" 2>"$proxy_out.err" &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null; rm -f "$proxy_out" "$proxy_out.err"' EXIT

for _ in $(seq 1 50); do grep -q '^port=' "$proxy_out" && break; sleep 0.1; done
PROXY_PORT=$(sed -n 's/^port=//p' "$proxy_out")
[ -n "$PROXY_PORT" ] || { echo "FAIL: proxy did not report a port"; cat "$proxy_out.err"; exit 1; }
echo "proxy listening on 127.0.0.1:$PROXY_PORT (allow: $ALLOWED_HOST)"

# 2. The command pasta runs inside the fresh net+user namespace. pasta has set
#    up an interface, address, default route and --map-gw (gateway address is
#    redirected to the host, so the host proxy is reachable at the gateway).
#    We discover the gateway pasta chose, then DROP the default route and keep
#    only an on-link route to it: after this the proxy is the sole reachable
#    destination and everything else is "network unreachable".
export PROXY_PORT ALLOWED_HOST DENIED_HOST BLOCKHOLE_IP
inner='
set -u
gw=$(ip -4 route show default | awk "{print \$3; exit}")
ifc=$(ip -4 route show default | awk "{print \$5; exit}")
[ -n "$gw" ] || { echo "FAIL: no gateway configured by pasta"; exit 1; }
ip route del default
ip route add "$gw/32" dev "$ifc" 2>/dev/null || true
P="http://$gw:$PROXY_PORT"
rc=0

# (1) allowlisted host, through the proxy → expect a real HTTP status
code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 -x "$P" "https://$ALLOWED_HOST/" || echo 000)
if [ "$code" -ge 200 ] && [ "$code" -lt 500 ] && [ "$code" != 403 ]; then
    echo "PASS  allowlisted $ALLOWED_HOST reachable via proxy (HTTP $code)"
else
    echo "FAIL  allowlisted $ALLOWED_HOST via proxy got HTTP $code"; rc=1
fi

# (2) non-allowlisted host, through the proxy → expect 403 from aye-proxy.
# Read %{http_connect} (the proxy'"'"'s response to the CONNECT), NOT %{http_code}
# (the tunnelled request'"'"'s status, which is 000 when the tunnel is refused).
code=$(curl -sS -o /dev/null -w "%{http_connect}" --max-time 15 -x "$P" "https://$DENIED_HOST/" 2>/dev/null)
code=${code:-000}
if [ "$code" = 403 ]; then
    echo "PASS  non-allowlisted $DENIED_HOST refused by proxy (403)"
else
    echo "FAIL  non-allowlisted $DENIED_HOST via proxy got CONNECT $code (want 403)"; rc=1
fi

# (3) raw egress bypassing the proxy → must have NO route (reverse-shell path)
if curl -sS --noproxy "*" --max-time 5 -o /dev/null "https://$BLOCKHOLE_IP/" 2>/dev/null; then
    echo "FAIL  raw egress to $BLOCKHOLE_IP succeeded — reverse shell would work"; rc=1
else
    echo "PASS  raw egress to $BLOCKHOLE_IP blocked (no route)"
fi

# (4) bash /dev/tcp reverse-shell primitive → must fail
if timeout 5 bash -c "exec 3<>/dev/tcp/$BLOCKHOLE_IP/443" 2>/dev/null; then
    echo "FAIL  /dev/tcp to $BLOCKHOLE_IP:443 connected — reverse shell would work"; rc=1
else
    echo "PASS  /dev/tcp reverse-shell primitive blocked"
fi

exit $rc
'

echo "entering namespace via pasta..."
pasta --config-net -- bash -c "$inner"
status=$?

echo
if [ "$status" -eq 0 ]; then
    echo "RESULT: egress mechanism verified — proxy is the sole exit, raw egress blocked."
else
    echo "RESULT: FAILED (exit $status) — do not wire this into aye-buddy yet."
fi
exit "$status"
