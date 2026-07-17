#!/usr/bin/env bash
# seccomp-check.sh — verify the seccomp denylist actually installs on a real
# machine, exercising the fd-arming path the unit tests can't reach: AyeSeccomp
# splices a real fd into `bwrap --seccomp <fd>`. The tests stub bwrap (which
# ignores --seccomp), so nothing else proves the natural fd is accepted and the
# filter takes effect.
#
# NOT run by `make test`: needs unprivileged user namespaces + bwrap.
#
# Probe: unshare(CLONE_NEWUSER) via `unshare -U true`. Creating a user namespace
# needs NO capability (that's the point of unprivileged userns), so it succeeds
# for the cap-dropped, no_new_privs payload — UNLESS seccomp forbids it, which
# filter.bpf does (deny_nest: unshare/mount/... is the escape vector the denylist
# exists to block). So without the blob it's SET, with the blob DENIED, and the
# gap is the filter. sethostname etc. are no good here: bwrap drops caps before
# exec, so they fail either way and the seccomp effect is invisible. If even the
# baseline can't unshare (nested userns disabled), we SKIP rather than cry wolf.
#
# Usage:  t/manual/seccomp-check.sh
# Needs:  bwrap, unshare(1), perl, and filter.bpf (run `make seccomp`).
set -u

here=$(cd "$(dirname "$0")/../.." && pwd)
blob="$here/filter.bpf"

command -v bwrap   >/dev/null || { echo "SKIP: bwrap not installed"; exit 2; }
command -v unshare >/dev/null || { echo "SKIP: unshare(1) not available for the probe"; exit 2; }
[ -f "$blob" ]                || { echo "SKIP: $blob not built (run: make seccomp)"; exit 2; }
[ -f "$here/AyeSeccomp.pm" ]  || { echo "SKIP: $here/AyeSeccomp.pm not found"; exit 2; }

# Runs inside bwrap: try to create a nested user namespace. SET means the
# syscall went through; DENIED means it was rejected (by seccomp, in the armed
# run — filter.bpf denies unshare).
probe='unshare -U true 2>/dev/null && echo SET || echo DENIED'
export PROBE="$probe" BLOB="$blob"

# Baseline: same sandbox, NO seccomp blob.
baseline=$(bwrap --unshare-user --dev-bind / / -- bash -c "$PROBE")

# Armed: build the bwrap argv with the placeholder, then let AyeSeccomp open the
# blob, clear cloexec, and splice the real fd in — exactly as aye-buddy's
# unfiltered path does — and exec bwrap. $keep holds the fd open through exec.
armed=$(perl -I"$here" -MAyeSeccomp=arm_seccomp,SECCOMP_FD_TOKEN -e '
    my @argv = ("--unshare-user", "--seccomp", SECCOMP_FD_TOKEN,
                "--dev-bind", "/", "/", "--", "bash", "-c", $ENV{PROBE});
    my $keep = arm_seccomp(\@argv, $ENV{BLOB});
    exec { "bwrap" } "bwrap", @argv or die "exec bwrap: $!\n";
')

echo "baseline (no seccomp): ${baseline:-<empty>}"
echo "armed    (filter.bpf): ${armed:-<empty>}"

if [ "$baseline" != SET ]; then
    echo "SKIP: baseline could not create a user namespace (got '${baseline:-<empty>}') —"
    echo "      nested userns is disabled here, so the seccomp effect isn't observable."
    exit 2
fi
if [ "$armed" != DENIED ]; then
    echo "FAIL: the seccomp blob did NOT deny unshare (got '${armed:-<empty>}') —"
    echo "      the arm_seccomp -> 'bwrap --seccomp <fd>' path is broken."
    exit 1
fi
echo "RESULT: seccomp arming verified — the denylist installs via bwrap --seccomp <fd>."
exit 0
