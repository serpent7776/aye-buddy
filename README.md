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

Installs `aye-buddy` and its helpers into `libexec/aye-buddy` and symlinks
the script onto your `$PATH`, then offers to add a `claude` shell function
that forwards to it (so typing `claude` runs the sandboxed version;
`command claude` still reaches the real binary).

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
| `--allow-host HOST[:PORT]` | Add one host to the network allowlist, matched exactly; `.HOST` covers its subdomains too. Port-less allows 443; `:PORT` allows exactly that port. Repeatable. |
| `--no-net-filter` | Turn off egress filtering and use the host network directly. |
| `--no-lan-filter` | Let the session reach same-subnet (LAN) hosts directly, around the proxy — see below. |
| `--allow-reserved` | Let an allowlisted *name* resolve to a loopback or private address. Off by default — see below. |
| `--allow-ssh` | Forward your SSH agent socket into the session. Off by default — see below. |
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

**Forwarded:** the filtered network, a minimal set of environment
variables, and — only with `--allow-ssh` — your SSH agent socket. Every
other env var, API tokens and cloud credentials included, is cleared so it
can't leak in.

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

An entry matches that hostname and nothing else: `--allow-host example.com`
does not open `anything.example.com`, and the default `github.com` does not
include `codeload.github.com`.

Prefix it with a dot to cover the subdomains as well — `--allow-host
.example.com` opens `example.com` and everything under it. That's one entry
instead of a list, at the cost of a tunnel to every name the domain's owner
cares to create, running whatever they run on the allowed port: `.github.com`
reaches `ssh.github.com:443`, which speaks SSH, not HTTPS. Prefer naming the
hosts you actually need.

Check who the owner is before you use it. A bare suffix like `.com` is
rejected, but that's a typo-catcher, not a public-suffix check: `.github.io`,
`.pages.dev` and `.co.uk` all pass, and each opens a domain anyone can get a
name under — an exfil endpoint that costs an attacker one signup. The dotted
form is for a domain one party controls, not for a hosting suffix.

Only HTTPS is reachable. The proxy tunnels `CONNECT` and serves no other
verb, so an `http://` URL fails with a 405 whatever the allowlist says —
`--allow-host example.com:80` opens port 80 to a client that tunnels for
itself (`curl --proxytunnel`), not to plain HTTP. Use `https://`.

WebSearch runs on Anthropic's servers, so it keeps working; only WebFetch
(which fetches from your machine) is subject to the allowlist.

Only IPv4 destinations are reachable. The proxy dials origins over IPv4
and the session's IPv6 egress is sealed, so an IPv6 literal is rejected by
`--allow-host` and an IPv6-only hostname won't connect — use an IPv4 or
dual-stacked host.

**This is egress control, not prevention — the residual risks:**

- **Anything you allow is a two-way channel.** Data can still leave via an
  allowlisted host (a GitHub gist, a package registry). Keep the list
  minimal.
- **No TLS interception.** The proxy decides by hostname without
  terminating TLS, so SNI spoofing / domain fronting can reach an off-list
  host that shares infrastructure with an allowed one.
- **SSH remotes aren't proxied automatically.** `ssh` doesn't honour
  `HTTPS_PROXY` — prefer HTTPS remotes, or allowlist the host and route
  `ssh` through the proxy with a `ProxyCommand` (and see
  [`--allow-ssh`](#--allow-ssh-agent-forwarding) for the key half).

`--no-net-filter` turns all of this off and restores full network access
— useful for debugging or a workload the allowlist can't express.

## `--allow-reserved` (names pointing inward)

The proxy runs on the host, outside the namespace the session is sealed
into, so it can reach addresses the session itself has no route to. Passing
the allowlist is therefore not enough on its own: a name is refused if it
resolves to loopback, RFC1918, link-local (including the
`169.254.169.254` metadata address), or other reserved space. Otherwise
allowlisting a domain whose records you don't fully control — a `.HOST`
entry especially — would hand the session a tunnel to your own machine or
LAN, around the seal. The address that passed the check is the one dialled,
so a second lookup can't answer differently.

Allowlisting an *address* is unaffected: `--allow-host 10.0.0.5:8080` says
which address you mean, so it is dialled as asked. The rule only applies to
names, and only to addresses DNS produced.

`--allow-reserved` turns the check off, for split-horizon DNS where an
internal name legitimately resolves into private space. It applies to every
allowlisted name in the session, so prefer naming the address outright
where you can.

## `--no-lan-filter` (direct LAN access)

Routing inside the session normally narrows to a single host route to the
proxy, so LAN hosts have no path at all. `--no-lan-filter` keeps the on-link
subnet route instead: the session reaches every address on that subnet on a
raw socket, around the proxy, the allowlist, the port scoping and the DENY
log. The internet stays unrouted either way — this opens the LAN, nothing
more — but it is the one unmediated path out of the sandbox, so it is off by
default.

Reach for it only for traffic the proxy can't carry: UDP, or a protocol that
negotiates its own ports. A plain TCP service is better named outright with
`--allow-host 10.0.0.5:5432`, which allowlists that address and port alone.
The proxy dials it from the host and tunnels it in, with no route from the
session to the subnet — and since the entry names an address rather than a
name, [`--allow-reserved`](#--allow-reserved-names-pointing-inward) isn't
needed either. Clients that don't speak `CONNECT` for themselves need a shim
in front (`socat TCP-LISTEN:5432,reuseaddr,fork
PROXY:$GW:10.0.0.5:5432,proxyport=$PORT`).

## `--allow-bwrap` (nested sandboxing)

By default the session can't create new namespaces or run `bwrap` itself.
`--allow-bwrap` lets it build inner sandboxes (e.g. to run a test suite
under bwrap), at the cost of a wider syscall surface and turning off the
Landlock layer for the session. It's opt-in and prints a warning, because
it reduces isolation. The host kernel must permit nested unprivileged user
namespaces (the default wherever `bwrap` already works).

## `--allow-ssh` (agent forwarding)

Off by default: the session gets no `SSH_AUTH_SOCK`, so `ssh` and
git-over-SSH inside it have no key to offer. `--allow-ssh` binds the host
agent's socket in at `/run/ssh-agent` (the private keys themselves stay
invisible, as with any agent forward) and prints a warning.

The warning is there because an agent signature can't be scoped to a
destination: for as long as the session runs it can ask your agent to
authenticate to *any* host it can reach, not only the git remote you had in
mind. Under the egress filter that's a short list — reaching an SSH host at
all needs `--allow-host` plus a `ProxyCommand` — but the capability is
wider than the use, so it's a deliberate choice rather than a default.

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

## Development

The seccomp denylists (`filter.bpf`, `filter-nested.bpf`) are committed blobs
generated from `gen-seccomp.c`; regenerate them with `make seccomp` after
editing the source. That also refreshes `seccomp.stamp`, a checksum of the
source the blobs were built from — `make check-stamp` verifies it and runs
first under `make test`, so a forgotten rebuild fails the tests on any
machine, no toolchain required.

## License

MIT — see [LICENSE](LICENSE).
