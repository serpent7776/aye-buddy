#!/bin/sh
# Install aye-buddy onto $PATH and, after prompting, add a claude() shell
# function that forwards to it.

set -eu

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

install -d "$BINDIR"
install -m 0755 "$SRC_DIR/$SCRIPT" "$BINDIR/$SCRIPT"
printf 'installed %s -> %s\n' "$SCRIPT" "$BINDIR/$SCRIPT"

for f in AyeSeccomp.pm ll-helper aye-proxy aye-net-helper filter.bpf filter-nested.bpf; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        msg="install.sh: required $SRC_DIR/$f not found"
        case "$f" in *.bpf) msg="$msg (run \`make seccomp\` to build it)" ;; esac
        echo "$msg" >&2
        exit 1
    fi
    case "$f" in
        *.bpf|*.pm) mode=0644 ;;
        *)          mode=0755 ;;
    esac
    install -m "$mode" "$SRC_DIR/$f" "$BINDIR/$f"
    printf 'installed %s -> %s\n' "$f" "$BINDIR/$f"
done

case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) printf 'warning: %s is not in PATH — add it to your shell rc\n' "$BINDIR" ;;
esac

if [ ! -t 0 ]; then
    echo "skipping claude shell function (stdin is not a tty)"
    exit 0
fi

printf "Install a 'claude' shell function that forwards to aye-buddy? [y/N] "
read -r ans
case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "skipping shell function install"; exit 0 ;;
esac

shell_path=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7 || true)
[ -n "${shell_path:-}" ] || shell_path=${SHELL:-/bin/sh}

case "$(basename "$shell_path")" in
    fish)
        func_file=$HOME/.config/fish/functions/claude.fish
        if [ -f "$func_file" ]; then
            printf 'claude function already present at %s\n' "$func_file"
            exit 0
        fi
        mkdir -p "$(dirname "$func_file")"
        cat > "$func_file" <<'EOF'
function claude
    command aye-buddy --agent claude $argv
end
EOF
        printf 'wrote %s\n' "$func_file"
        ;;
    *)
        case "$(basename "$shell_path")" in
            zsh)  rc=$HOME/.zshrc  ;;
            bash) rc=$HOME/.bashrc ;;
            *)    rc=$HOME/.profile ;;
        esac
        marker='# aye-buddy: claude shell function'
        if [ -f "$rc" ] && grep -qF "$marker" "$rc"; then
            printf 'claude function already present in %s\n' "$rc"
            exit 0
        fi
        {
            printf '\n%s\n' "$marker"
            printf 'claude() { command aye-buddy --agent claude "$@"; }\n'
        } >> "$rc"
        printf 'added claude() to %s — run: source %s\n' "$rc" "$rc"
        ;;
esac
