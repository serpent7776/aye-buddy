#!/bin/sh
# Install aye-buddy onto $PATH and, after prompting, add a claude() shell
# function that forwards to it.
#
# usage: install.sh [-y|-n]
#   -y  assume yes to every prompt (never asks, works without a tty)
#   -n  assume no to every prompt

set -eu

# Answer to the shell-function prompt, if supplied up front: y or n.
assume=""
for arg in "$@"; do
    case "$arg" in
        -y|-n)
            if [ -n "$assume" ] && [ "$assume" != "${arg#-}" ]; then
                echo "install.sh: -y and -n are mutually exclusive" >&2
                exit 2
            fi
            assume=${arg#-}
            ;;
        *)
            echo "usage: install.sh [-y|-n]" >&2
            exit 2
            ;;
    esac
done

SCRIPT=aye-buddy
SRC_DIR=$(cd "$(dirname "$0")" && pwd)

if [ ! -f "$SRC_DIR/$SCRIPT" ]; then
    echo "install.sh: $SRC_DIR/$SCRIPT not found" >&2
    exit 1
fi

# Pick the first user-owned bin dir already on $PATH; fall back to ~/.local/bin.
BINDIR=""
for d in "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in
        *":$d:"*) BINDIR=$d; break ;;
    esac
done
: "${BINDIR:=$HOME/.local/bin}"

LIBEXEC=$HOME/.local/libexec/aye-buddy
install -d "$LIBEXEC"

# A checkout still has the $Format:%h$ placeholder that `git archive` would
# have expanded (GitHub's tgz/zip arrive filled in). Fill it from git when it
# is there; without git the installed copy just prints the bare version.
hash=""
if grep -q 'Format:%h' "$SRC_DIR/$SCRIPT"; then
    hash=$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null) || hash=""
fi

for f in "$SCRIPT" AyeSeccomp.pm Claude.pl aye-landlock aye-proxy aye-netns-seal filter.bpf filter-nested.bpf; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        msg="install.sh: required $SRC_DIR/$f not found"
        case "$f" in *.bpf) msg="$msg (run \`make seccomp\` to build it)" ;; esac
        echo "$msg" >&2
        exit 1
    fi
    case "$f" in
        *.bpf|*.pm|*.pl) mode=0644 ;;
        *)          mode=0755 ;;
    esac
    if [ "$f" = "$SCRIPT" ] && [ -n "$hash" ]; then
        sed 's/\$Format:%h\$/'"$hash"'/' "$SRC_DIR/$f" > "$LIBEXEC/$f.tmp"
        install -m "$mode" "$LIBEXEC/$f.tmp" "$LIBEXEC/$f"
        rm -f "$LIBEXEC/$f.tmp"
    else
        install -m "$mode" "$SRC_DIR/$f" "$LIBEXEC/$f"
    fi
    printf 'installed %s -> %s\n' "$f" "$LIBEXEC/$f"
done

install -d "$BINDIR"
ln -sf "$LIBEXEC/$SCRIPT" "$BINDIR/$SCRIPT"
printf 'linked %s -> %s\n' "$BINDIR/$SCRIPT" "$LIBEXEC/$SCRIPT"

case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) printf 'warning: %s is not in PATH — add it to your shell rc\n' "$BINDIR" ;;
esac

if [ -z "$assume" ]; then
    if [ ! -t 0 ]; then
        echo "skipping claude shell function (stdin is not a tty)"
        exit 0
    fi
    printf "Install a 'claude' shell function that forwards to aye-buddy? [y/N] "
    read -r assume
fi
case "$assume" in
    y|Y|yes|YES) ;;
    *) echo "skipping shell function install"; exit 0 ;;
esac

shell_path=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7 || true)
[ -n "${shell_path:-}" ] || shell_path=${SHELL:-/bin/sh}

case "$(basename "$shell_path")" in
    fish)
        func_file=$HOME/.config/fish/functions/claude.fish
        existed=false
        [ -f "$func_file" ] && existed=true
        mkdir -p "$(dirname "$func_file")"
        cat > "$func_file" <<'EOF'
function claude
    command aye-buddy --agent claude $argv
end
EOF
        if $existed; then
            printf 'updated %s\n' "$func_file"
        else
            printf 'wrote %s\n' "$func_file"
        fi
        ;;
    *)
        case "$(basename "$shell_path")" in
            zsh)  rc=$HOME/.zshrc  ;;
            bash) rc=$HOME/.bashrc ;;
            *)    rc=$HOME/.profile ;;
        esac
        marker='# aye-buddy: claude shell function'
        # Drop any prior aye-buddy block (marker + the function line after it)
        # so re-running replaces it instead of appending a duplicate.
        existed=false
        if [ -f "$rc" ] && grep -qF "$marker" "$rc"; then
            existed=true
            tmp=$(mktemp "${TMPDIR:-/tmp}/aye-buddy.XXXXXX")
            awk -v m="$marker" 'skip { skip=0; next } $0==m { skip=1; next } { print }' \
                "$rc" > "$tmp"
            cat "$tmp" > "$rc"
            rm -f "$tmp"
        fi
        {
            printf '\n%s\n' "$marker"
            printf 'claude() { command aye-buddy --agent claude "$@"; }\n'
        } >> "$rc"
        if $existed; then
            printf 'updated claude() in %s — run: source %s\n' "$rc" "$rc"
        else
            printf 'added claude() to %s — run: source %s\n' "$rc" "$rc"
        fi
        ;;
esac
