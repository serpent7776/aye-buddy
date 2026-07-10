#!/usr/bin/env bash
# egress-check.sh — verify the Tier-3 egress mechanism on a real machine.
#
# This is NOT run by `make test`: it needs unprivileged user+net namespaces,
# which don't exist in every CI/sandbox. It drives the SAME artifacts aye-buddy
# ships — aye-proxy (allowlist) and aye-net-helper (route restriction inside
# pasta's netns) — WITHOUT bwrap, so a failure points at the plumbing, not the
# file sandbox.
#
# It proves the property the whole feature rests on:
#   1. an allowlisted host is reachable *through the proxy*
#   2. a non-allowlisted host is refused (403) by the proxy
#   3. anything NOT going through the proxy has no route out — i.e. a raw-socket
#      reverse shell to an off-subnet IP cannot connect
#
# Usage:  t/manual/egress-check.sh
# Needs:  pasta, curl, ip, timeout, and aye-proxy + aye-net-helper in the repo.
set -u

here=$(cd "$(dirname "$0")/../.." && pwd)
proxy_bin="$here/aye-proxy"
net_helper="$here/aye-net-helper"

ALLOWED_HOST=${ALLOWED_HOST:-example.com}      # on the allowlist
DENIED_HOST=${DENIED_HOST:-cloudflare.com}     # deliberately not
BLOCKHOLE_IP=${BLOCKHOLE_IP:-1.1.1.1}          # off-subnet raw-egress probe

command -v pasta  >/dev/null || { echo "SKIP: pasta not installed"; exit 2; }
command -v curl   >/dev/null || { echo "SKIP: curl not installed";  exit 2; }
[ -x "$proxy_bin" ]          || { echo "SKIP: $proxy_bin not found"; exit 2; }
[ -f "$net_helper" ]         || { echo "SKIP: $net_helper not found"; exit 2; }

# 1. Start aye-proxy on the host (it has real network; the netns will not).
proxy_out=$(mktemp)
"$proxy_bin" --allow "$ALLOWED_HOST" --port 0 >"$proxy_out" 2>"$proxy_out.err" &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null; rm -f "$proxy_out" "$proxy_out.err"' EXIT

for _ in $(seq 1 50); do grep -q '^port=' "$proxy_out" && break; sleep 0.1; done
PROXY_PORT=$(sed -n 's/^port=//p' "$proxy_out")
[ -n "$PROXY_PORT" ] || { echo "FAIL: proxy did not report a port"; cat "$proxy_out.err"; exit 1; }
echo "proxy listening on 127.0.0.1:$PROXY_PORT (allow: $ALLOWED_HOST)"

# 2. The assertions, run inside the namespace. aye-net-helper (spawned by pasta,
#    below) has already dropped the default route and exported HTTP(S)_PROXY, so
#    here we just probe. Vars are inherited through pasta -> helper -> bash.
export ALLOWED_HOST DENIED_HOST BLOCKHOLE_IP
inner='
set -u
echo "--- ns routes (default dropped by aye-net-helper) ---"; ip -4 route show
P="$HTTP_PROXY"
rc=0

# (1) allowlisted host, through the proxy → a real HTTP status
code=$(timeout 15 curl -sS -o /dev/null -w "%{http_code}" -x "$P" "https://$ALLOWED_HOST/" 2>/dev/null || echo 000)
if [ "$code" -ge 200 ] && [ "$code" -lt 500 ] && [ "$code" != 403 ]; then
    echo "PASS  allowlisted $ALLOWED_HOST reachable via proxy (HTTP $code)"
else
    echo "FAIL  allowlisted $ALLOWED_HOST via proxy got HTTP $code"; rc=1
fi

# (2) non-allowlisted host → expect 403 from the proxy. Read %{http_connect}
# (the CONNECT response), NOT %{http_code} (000 when the tunnel is refused).
code=$(timeout 15 curl -sS -o /dev/null -w "%{http_connect}" -x "$P" "https://$DENIED_HOST/" 2>/dev/null)
code=${code:-000}
if [ "$code" = 403 ]; then
    echo "PASS  non-allowlisted $DENIED_HOST refused by proxy (403)"
else
    echo "FAIL  non-allowlisted $DENIED_HOST via proxy got CONNECT $code (want 403)"; rc=1
fi

# (3) raw egress bypassing the proxy → must have NO route (reverse-shell path)
if timeout 6 curl -sS --noproxy "*" -o /dev/null "https://$BLOCKHOLE_IP/" 2>/dev/null; then
    echo "FAIL  raw egress to $BLOCKHOLE_IP succeeded — reverse shell would work"; rc=1
else
    echo "PASS  raw egress to $BLOCKHOLE_IP blocked (no route)"
fi

# (4) bash /dev/tcp reverse-shell primitive → must fail
if timeout 6 bash -c "exec 3<>/dev/tcp/$BLOCKHOLE_IP/443" 2>/dev/null; then
    echo "FAIL  /dev/tcp to $BLOCKHOLE_IP:443 connected — reverse shell would work"; rc=1
else
    echo "PASS  /dev/tcp reverse-shell primitive blocked"
fi

exit $rc
'

echo "entering namespace via pasta -> aye-net-helper ..."
# "-" = no seccomp blob (no bwrap in this harness); the helper drops the route
# and exports the proxy env, then execs our probe.
pasta --config-net -- "$net_helper" "$PROXY_PORT" - -- bash -c "$inner"
status=$?

echo
if [ "$status" -eq 0 ]; then
    echo "RESULT: egress mechanism verified — proxy is the sole exit, raw egress blocked."
else
    echo "RESULT: FAILED (exit $status) — do not wire this into aye-buddy yet."
fi
exit "$status"
