# aye-buddy

Aye-buddy is your AI buddy. It runs Claude Code in a sandbox so a session can
only touch the project you're working on — not your SSH keys, cloud
credentials, browser profiles, other projects or personal files.

## Why

A Claude Code session runs shell commands and reads files with your full
user permissions. Without isolation it can reach `~/.ssh`, `~/.aws`,
`~/.netrc`, password stores, other repos, and shell history — either
because the model treats them as "relevant context" or because a prompt
injection (in a fetched page, a dependency's README, an issue comment)
tells it to exfiltrate them.

`aye-buddy` wraps `claude` so that:

- **Only the current project and a few Claude config paths are visible.**
  Everything else under `$HOME` — and most of the system — simply isn't
  there.
- **Network egress is filtered.** The session reaches the
  network only through a bundled proxy that allows a small list of hosts
  (Claude API, common package registries, git over HTTPS). Everything else
  has no route out, so an injected "open a reverse shell" command can't
  phone home.
- **It can't inject keystrokes into your terminal.** The session gets a
  fresh session with no controlling terminal, closing the `TIOCSTI`
  keystroke-injection escape.

Out of scope: kernel escapes, and anything you run outside the wrapper.
The network layer is egress *control*, not *prevention* — see
[the caveats](#network-filtering).

## Requirements

- `perl` (core modules only — nothing from CPAN)
- `bwrap` (bubblewrap)
- `claude` (Claude Code CLI)
- a `git` or `jj` repository (the wrapper refuses to run outside one)

For the network filter, which is on by default — `--no-net-filter` needs none
of these:

- `pasta` (from `passt`)
- `ip` (from `iproute2`)
- `nft` (from `nftables`) — optional. Without it the egress seal still holds,
  but the host-loopback and IPv6 side channels stay reachable; the session
  warns and carries on.

## Install

```
make install
```

Copies `aye-buddy` and its helpers onto your `$PATH`, then offers to add a
`claude` shell function that forwards to it (so typing `claude` runs the
sandboxed version; `command claude` still reaches the real binary).

`make uninstall` reverses it (for bash/zsh you remove the shell-function
block by hand — the installer prints where).

## Usage

Run `aye-buddy` (or `claude`, with the shell function) from inside a
project. Arguments forward to `claude`:

```
aye-buddy
aye-buddy -p "summarise this repo"
```

`aye-buddy`'s own flags go **before** claude's arguments; use `--` to end
them explicitly. Passing one after claude's arguments is an error rather
than being silently forwarded.

| Flag | Effect |
| --- | --- |
| `--agent NAME` | Which agent to run (default `claude`). Only `claude` is supported today. |
| `--bind PATH` | Expose an extra host path (read-write) at the same path inside the sandbox. Repeatable. |
| `--bind-ro PATH` | Same, read-only. Repeatable. |
| `--allow-host HOST[:PORT]` | Add a host to the network allowlist. Port-less allows 80/443. Repeatable. |
| `--no-net-filter` | Turn off egress filtering and use the host network directly. |
| `--allow-subnet` | Keep same-subnet (LAN) hosts reachable under the filter. |
| `--allow-bwrap` | Let the session run `bwrap` itself (nested sandboxing). Reduces isolation — see below. |
| `--help` | Print the flag list and exit. |
| `--version` | Print the version and exit. |

`--help` and `--version` are answered before anything is set up, so they work
outside a repository. To reach claude's own `--help`, put it after the
separator: `aye-buddy -- --help`.

Paths inside the sandbox match host paths exactly, so error messages and
stack traces open correctly in your editor.

## What the session can see

**Read-write:** the project root (only this one), most of `~/.claude/`
(so `--continue` and history work), `~/.claude.json`, and a cache directory
of aye-buddy's own (see [Caches](#caches)).

**Read-only:** system dirs (`/usr`, `/etc`, `/opt`, `/nix`); your git and
SSH *config* (`~/.gitconfig`, `~/.ssh/config`, `~/.ssh/known_hosts`); the
project's `.git/hooks`, `.git/config`, `.git/modules`; and the parts of
`~/.claude/` that could inject code into a later host-side `claude` run
(`settings.json`, `commands/`, `agents/`, `plugins/`, `hooks/`,
`scripts/`, `mcp.json`). Config that a session shouldn't be able to change
under you stays read-only; the rest is writable so Claude's own state
keeps working.

**Forwarded:** your SSH agent socket (if `SSH_AUTH_SOCK` is set), the
filtered network, and a minimal set of environment variables. Every other
env var — API tokens, cloud credentials — is cleared so it can't leak in.

**Not visible at all:** `~/.ssh` private keys, `~/.aws`, `~/.config/gcloud`,
`~/.kube`, `~/.netrc`, browser profiles, password stores, other projects,
other users' homes, `/root`, `/var`, and your real caches (`~/.cache`,
`~/.cargo`, `~/.npm`). `$HOME` starts as an empty tmpfs; only the paths above
are mounted in.

## Caches

`$HOME` is a tmpfs, so anything written there would live in RAM and vanish
with the session — package caches would be re-downloaded every run. So
`~/.cache` inside the sandbox is a real directory on disk,
`~/.cache/aye-buddy` (or `$XDG_CACHE_HOME/aye-buddy`), shared by every
session. `CARGO_HOME`, `GOPATH` and npm's cache point into it too, since
those tools ignore `XDG_CACHE_HOME`.

Only that one subdirectory is mounted; the rest of your `~/.cache` stays
invisible, along with `~/.cargo` and `~/.npm`. That's deliberate. `~/.cargo`
is not a cache directory — it holds `bin/` (usually on your `$PATH`),
`config.toml` (which can run commands on the next build) and
`credentials.toml` (your registry token). `~/.cache` holds other
applications' data, browser caches included. And host-side tools *trust*
their caches, so a writable bind would let a session poison a build you run
later outside the sandbox.

It's an ordinary cache: delete it whenever you like. Sandboxed projects share
it, so it is not an isolation boundary between them.

## Network filtering

On by default. The session runs in its own network namespace whose only
way out is a bundled filtering proxy: allowlisted HTTPS hosts are
tunnelled through, and everything else — including a raw-socket reverse
shell — has no route at all.

The default allowlist covers the Claude API, the major package registries
(npm, PyPI, crates.io, Go), and git over HTTPS. Add to it with
`--allow-host`:

```
aye-buddy --allow-host git.internal.corp --allow-host registry.example:443
```

WebSearch runs on Anthropic's servers, so it keeps working; only WebFetch
(which fetches from your machine) is subject to the allowlist.

**This is egress control, not prevention — the residual risks:**

- **Anything you allow is a two-way channel.** Data can still leave via an
  allowlisted host (a GitHub gist, a package registry). Keep the list
  minimal.
- **No TLS interception.** The proxy decides by hostname without
  terminating TLS, so SNI spoofing / domain fronting can reach an off-list
  host that shares infrastructure with an allowed one.
- **SSH remotes aren't proxied automatically.** `ssh` doesn't honour
  `HTTPS_PROXY` — prefer HTTPS remotes, or allowlist the host and route
  `ssh` through the proxy with a `ProxyCommand`.

`--no-net-filter` turns all of this off and restores full network access
— useful for debugging or a workload the allowlist can't express.

## `--allow-bwrap` (nested sandboxing)

By default the session can't create new namespaces or run `bwrap` itself.
`--allow-bwrap` lets it build inner sandboxes (e.g. to run a test suite
under bwrap), at the cost of a wider syscall surface and turning off the
Landlock layer for the session. It's opt-in and prints a warning, because
it reduces isolation. The host kernel must permit nested unprivileged user
namespaces (the default wherever `bwrap` already works).

## Limitations

- **Project write actions aren't restricted.** The session runs with claude's
  permission prompts skipped, so it can run destructive in-project
  commands or `git push`. The threat model is read-exfil and egress, not
  write protection.
- **Git worktrees and submodule working dirs are refused.** Their `.git`
  points outside the project directory, which the sandbox doesn't bind, so
  git would break inside. Run from the main checkout instead.
- **Some in-session config writes fail.** Settings that `claude` persists
  to `~/.claude/settings.json` (e.g. `/effort`) error because that file is
  read-only in the sandbox. Set them on the host beforehand, or pass them
  per invocation.
- **`~/.claude` is shared with host-run sessions.** A session in project A
  can read transcripts from project B under `~/.claude/projects/`. Accepted
  trade for unified history.

## Tests

```
make test
```

Black-box tests for option parsing and the egress helpers (`t/`). The full
network mechanism needs real namespaces and is verified out-of-band by
`t/manual/egress-check.sh`.

## License

MIT — see [LICENSE](LICENSE).
