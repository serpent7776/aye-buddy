#!/usr/bin/env bash
# overlay-check.sh — verify the worktree overlays on a real machine: writes a
# session makes under the project's .claude/worktrees and .git/worktrees land
# in a throwaway upper and never reach the host, while the project .claude
# itself is read-only. The unit tests only see the bwrap argv aye-buddy builds;
# this runs against the real mounts.
#
# NOT run by `make test`: it needs a live session, and the check is stateful.
#
# Two phases, because aye-buddy can only launch claude, so the in-session half
# has to be run from inside a session by hand
#
#   1. Start a session for this purpose alone, in the project you want to test,
#      and FIRST THING run:   ! t/manual/overlay-check.sh session
#      It plants a marker in every overlay, copies up and whites out an
#      existing file where one is there (a touch, and a delete-then-recreate),
#      and does a real `git worktree add`. What it touched goes into a manifest under the
#      persistent cache dir. Then exit the session — nothing else it does
#      matters, and a second run in the same session would record the upper's
#      copies and misreport.
#   2. On the host, from the same project root:
#                             t/manual/overlay-check.sh host
#      Reads the manifest, confirms every marker is gone and every touched file
#      still has its old content and ctime, and cleans up the branch (refs are
#      bound rw, so that one is expected to persist).
#
# Usage:  t/manual/overlay-check.sh session|host
# Needs:  git, coreutils.
set -u

marker=aye-overlay-check.marker
wt=aye-overlay-check
phase=${1:-}

fstype() { stat -f -c %T "$1" 2>/dev/null; }
sum()    { cksum < "$1" | cut -d' ' -f1; }
ctime()  { stat -c %Z "$1"; }

case $phase in
session)
    # Inside the sandbox the persistent cache is bound at ~/.cache itself.
    manifest="$HOME/.cache/overlay-check.manifest"
    project=$(pwd -P)   # aye-buddy binds the project at its physical path
    [ -d "$project/.git" ] || { echo "run from the project root (no .git here)"; exit 1; }
    # Only inside a session: the worktrees dir is an overlay AND the project
    # .claude is read-only. A host whose root is itself overlayfs fails the
    # second, and must, since everything below would then hit real files.
    if [ "$(fstype "$project/.claude/worktrees")" != overlayfs ] || [ -w "$project/.claude" ]; then
        echo "SKIP: this is not a sandboxed view of $project; run this inside a session"
        exit 2
    fi
    rc=0
    pass() { echo "PASS  $1"; }
    fail() { echo "FAIL  $1"; rc=1; }
    : > "$manifest" || { echo "cannot write $manifest"; exit 1; }
    note() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "$manifest"; }
    note project "$project"   # the host phase checks it is run from here

    if touch "$project/.claude/$marker" 2>/dev/null; then
        fail "project .claude is writable"; rm -f "$project/.claude/$marker"
    else pass "project .claude is read-only"; fi

    for d in "$project/.claude/worktrees" "$project/.git/worktrees"; do
        [ -d "$d" ] || continue
        t=$(fstype "$d")
        [ "$t" = overlayfs ] || { fail "$d is $t, not overlayfs"; continue; }
        if [ -e "$d/$marker" ]; then
            fail "$d/$marker already present at session start; leaked from an earlier run?"
            continue
        fi
        if touch "$d/$marker"; then pass "new file under $d"; note absent "$d/$marker"
        else fail "cannot create under $d"; fi
        # Lower files, if any, for copy-up and whiteout. Their ctime is the
        # lower's, and a leak of either operation would bump it on the host.
        # Anything with a ctime newer than the session is in the upper: claude
        # writes a few files at startup. Not under .git/worktrees: its lower is
        # git metadata the worktree add below still needs to read.
        [ "$d" = "$project/.git/worktrees" ] && continue
        mapfile -t files < <(find "$d" -type f ! -name "$marker" ! -cnewer /proc/1 2>/dev/null | sort | head -2)
        if [ ${#files[@]} -ge 1 ]; then
            f=${files[0]}
            note intact "$f" "$(sum "$f")" "$(ctime "$f")"
            if touch "$f"; then pass "copy-up of $f"
            else fail "copy-up of $f refused"; fi
        else echo "SKIP  no existing file under $d to copy up"; fi
        if [ ${#files[@]} -ge 2 ]; then
            f=${files[1]}
            note intact "$f" "$(sum "$f")" "$(ctime "$f")"
            if cp -p "$f" "$f.aye-overlay-check" && rm "$f" && [ ! -e "$f" ] \
               && mv "$f.aye-overlay-check" "$f"
            then pass "whiteout and recreate of $f"
            else fail "whiteout of $f failed"; fi
        else echo "SKIP  no second file under $d to white out"; fi
    done

    if git show-ref --verify --quiet "refs/heads/$wt"; then
        fail "branch $wt already exists; run the host phase to clean up first"
    elif git worktree add -q -b "$wt" ".claude/worktrees/$wt" HEAD 2>&1 \
         && git worktree list | grep -q "/$wt "; then
        pass "git worktree add through both overlays"
        note absent "$project/.claude/worktrees/$wt"
        note absent "$project/.git/worktrees/$wt"
        note branch "$wt"
    else fail "git worktree add failed inside the session"; fi

    echo
    if [ $rc -eq 0 ]; then echo "SESSION OK: now exit the session and run: $0 host"
    else echo "SESSION FAILED: the sandbox view is wrong; the host phase can still check for leaks"; fi
    exit $rc
    ;;

host)
    cache=${XDG_CACHE_HOME:-}
    case $cache in /*) ;; *) cache="$HOME/.cache" ;; esac
    manifest="$cache/aye-buddy/overlay-check.manifest"
    [ -f "$manifest" ] || { echo "no manifest at $manifest; run the session phase first"; exit 1; }
    # The cache dir is writable by every session, so the manifest is untrusted:
    # the project is where we stand, only paths under the overlaid roots are
    # looked at, and the only branch ever deleted is the fixed test one.
    project=$(pwd -P)   # aye-buddy binds the project at its physical path
    [ -d "$project/.git" ] || { echo "run from the project root (no .git here)"; exit 1; }
    if [ "$(awk -F'\t' '$1 == "project" { print $2; exit }' "$manifest")" != "$project" ]; then
        echo "the manifest is for another project; run this from the one the session phase ran in"
        exit 1
    fi
    if [ ! -w "$project/.claude" ]; then
        echo "$project/.claude is read-only; run this phase on the host, not in a session"
        exit 1
    fi
    overlaid() {
        case $1 in
        "$project/.claude/worktrees/"*|"$project/.git/worktrees/"*) return 0 ;;
        esac
        return 1
    }
    rc=0
    while IFS=$'\t' read -r kind path arg arg2; do
        case $kind in
        absent|intact)
            if ! overlaid "$path"; then
                echo "FAIL  manifest names $path, outside the overlays; ignored"; rc=1
                continue
            fi ;;
        esac
        case $kind in
        absent)
            if [ -e "$path" ]; then
                echo "FAIL  $path leaked"; rc=1
                # Only our own markers are safe to remove; leave anything else
                # for inspection.
                case $path in */$marker) rm -f "$path" ;; esac
            else echo "PASS  $path absent"; fi ;;
        intact)
            if [ ! -f "$path" ]; then echo "FAIL  $path is gone"; rc=1
            elif [ "$(sum "$path")" != "$arg" ]; then echo "FAIL  $path content changed"; rc=1
            elif [ "$(ctime "$path")" != "$arg2" ]; then echo "FAIL  $path ctime changed; a copy-up or whiteout leaked"; rc=1
            else echo "PASS  $path untouched"; fi ;;
        branch)
            if git worktree list | grep -q "/$wt "; then
                echo "FAIL  git still lists the session's worktree $wt"; rc=1
            else echo "PASS  git worktree list has no $wt"; fi
            if git worktree prune -n 2>&1 | grep -q "$wt"; then
                echo "FAIL  git worktree prune finds a stale $wt entry"; rc=1
            else echo "PASS  git worktree prune finds no stale $wt"; fi
            # Refs are not overlaid (.git is bound rw), so the branch does
            # persist: the documented consequence, not a leak.
            if git show-ref --verify --quiet "refs/heads/$wt"; then
                echo "PASS  branch $wt persisted (refs are bound rw, by design); deleting"
                git branch -q -D "$wt" || { echo "FAIL  cannot delete branch $wt"; rc=1; }
            else echo "FAIL  branch $wt missing; refs should have persisted"; rc=1; fi ;;
        esac
    done < "$manifest"
    rm -f "$manifest"
    echo
    if [ $rc -eq 0 ]; then echo "RESULT: overlays verified; session writes under .claude never reached the host."
    else echo "RESULT: FAILED."; fi
    exit $rc
    ;;

*)
    echo "usage: $0 session|host" >&2
    exit 64
    ;;
esac
