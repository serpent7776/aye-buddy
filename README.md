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

- **Only the current project and a Claude state dir of its own are
  visible.** Everything else under `$HOME` — and most of the system —
  simply isn't there.
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

- `perl` (core modules only — nothing from CPAN), and POSIX `cp` and
  `chmod` for the state dir seeding
- `bwrap` (bubblewrap) 0.10 or newer — the worktree overlays need its
  overlay options, and a kernel that allows unprivileged overlayfs (5.11,
  or a vendor backport) on the filesystem holding the repo — probed at
  startup
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

To skip the question, run the installer directly: `./install.sh -y` adds
the function without asking (no tty needed), `./install.sh -n` leaves it out.

`make uninstall` reverses it (for bash/zsh you remove the shell-function
block by hand — the installer prints where).

The installed `aye-buddy --version` names the commit it came from. Release
archives from GitHub carry the hash already (via `git archive`'s
`export-subst`); installing from a checkout takes it from `git` when that is
on `PATH`. Neither git nor anything else is required — without it the bare
version prints.

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
| `--agent NAME` | Which agent to run (default `claude`). Only `claude` is supported today; an agent is one module beside `aye-buddy` (`Claude.pl` documents the interface) that names its binary, API hosts, config dir and what of it the session gets. |
| `--bind PATH` | Expose an extra host path (read-write) at the same path inside the sandbox. Repeatable. Paths overlapping `~/.claude` (either direction), the sandbox state root, or under the project's `.claude` are refused — the sandbox mounts its own view of those. |
| `--bind-ro PATH` | Same, read-only. Repeatable. |
| `--allow-host HOST[:PORT]` | Add one host to the network allowlist, matched exactly; `.HOST` covers its subdomains too. Port-less allows 443; `:PORT` allows exactly that port. Repeatable. |
| `--keep-env NAME` | Pass one environment variable through into the session instead of clearing it. Repeatable — see below. |
| `--reseed` | Copy the host's settings, skills and plugins into this project's sandbox state again, replacing the session's copy of them — see [Claude state](#claude-state). |
| `--no-net-filter` | Turn off egress filtering and use the host network directly. |
| `--no-lan-filter` | Let the session reach same-subnet (LAN) hosts directly, around the proxy — see below. |
| `--allow-reserved` | Let an allowlisted *name* resolve to a loopback or private address. Off by default — see below. |
| `--allow-ssh` | Forward your SSH agent socket into the session. Off by default — see below. |
| `--allow-bwrap` | Let the session run `bwrap` itself (nested sandboxing). Reduces isolation — see below. |
| `--help` | Print the flag list and exit. |
| `--version` | Print the version and exit, with the short commit hash when known (`aye-buddy 0.1.0-abc1234`). |

`--help` and `--version` are answered before anything is set up, so they work
outside a repository. To reach claude's own `--help`, put it after the
separator: `aye-buddy -- --help`.

Paths inside the sandbox match host paths exactly, so error messages and
stack traces open correctly in your editor.

## What the session can see

**Read-write:** the project root (only this one); a claude state dir of
aye-buddy's own for this project, mounted at `~/.claude` (see
[Claude state](#claude-state)); the host's `~/.claude/.credentials.json`,
mounted over it; and a cache directory of aye-buddy's own (see
[Caches](#caches)).

**Read-only:** system dirs (`/usr`, `/etc`, `/opt`, `/nix`); the parts
of `~/.claude` you write and `claude` only reads or runs, mounted over
the state dir at their paths (see [Claude state](#claude-state)); your git
*config* (`~/.gitconfig`, `~/.config/git`) and, only with `--allow-ssh`,
your SSH *config* (`~/.ssh/config`, `~/.ssh/known_hosts`); the
project's `.git/hooks`, `.git/config`, `.git/modules` and its `.claude/`
— a later host-side `claude` run in this repo acts on that dir, so a
session can't plant hooks, skills or settings there (it's created empty
when the repo has none, so the guard holds there too).

**Visible, writes discarded:** the worktree dirs, `.claude/worktrees/`
plus the `.git/worktrees/` admin dir, so in-session `git worktree` use
works without leaving the host repo a half-created worktree. Each is an
overlay: the host's files show through, and writes land in a tmpfs upper
layer that is thrown away at exit — except a worktree's commits and
branch, which live in the shared `.git`.

### Claude state

The host's `~/.claude` is never mounted whole. The session gets a state
dir of aye-buddy's own instead, one per project and agent, under
`~/.local/state/aye-buddy/claude/` (`XDG_STATE_HOME` honoured), named
after the project path: `/` becomes `-`, `-` becomes `__` and `_`
becomes `_-`, so `/home/me/src/my-app` is `-home-me-src-my__app`. It is
mounted at `~/.claude`, and `~/.claude.json` is served from it too.

The config a host-side `claude` loads is split by who writes it. What a
session writes is copied in on the first run in a project, so its edits
stay its own: `settings.json`, `settings.local.json`, and the `skills/`
and `plugins/` dirs. `~/.claude.json` is copied with its per-project map
cut down to this project, since the other entries name every repo
you've opened. What you write and `claude` only reads or runs is
mounted from the host, read-only, at the same paths, so an edit on the
host is what the session runs, and a session can't change what your
host-side `claude` runs: `CLAUDE.md`, `mcp.json`, `.mcp.json`,
`keybindings.json`, `statusline-command.sh`, and the `commands/`,
`agents/`, `output-styles/`, `rules/`, `workflows/`, `themes/`,
`hooks/` and `scripts/` dirs. A dir's edits show at once; a file an
editor replaces while a session runs reads as before in that session,
and as saved in the next. An item that is itself a symlink is followed,
as a dotfiles manager leaves it; links inside a copied one are copied
as links.
Everything else — other projects' transcripts, `history.jsonl`,
`file-history/` — stays out. That includes a script sitting directly in
`~/.claude/`: a hook command pointing at `~/.claude/foo.sh` gets ENOENT
inside the sandbox. Keep such scripts in `~/.claude/hooks/` or
`~/.claude/scripts/`.

From then on the copied part is the session's. Transcripts, prompt
history, memory, settings changed with `/effort` or `/config`, an
in-session plugin or skill install: all of it persists across runs of
this project, and none of it is read by a host-side `claude`. The copy
is not refreshed. A setting, skill or plugin you change on the host
reaches a project's sandbox only with `--reseed`, which replaces the
copied items — a session's additions inside them go with it — and keeps
the rest. It also clears whatever sits in the state dir where a host
item is mounted over it, which shows only once you remove that item on
the host: a copy made before it was mounted, or the empty mount point
bwrap leaves. A session that left a file, dir or link of the wrong kind
there is refused at the next start, naming `--reseed`. It refuses to
run while a session is up in that project, and a session refuses to
start while a reseed is in progress.

Only the credentials file is written on both sides: the host's is
mounted over the state dir's copy, so one login serves both.

`CLAUDE_CONFIG_DIR` is honoured: with it set, the state dir is seeded
from and mounted at that directory instead, `~/.claude.json` lives inside
it, and the variable is forwarded so the session looks there. A relative
value is refused.

**Forwarded:** the filtered network, a minimal set of environment
variables, and — only with `--allow-ssh` — your SSH agent socket. Every
other env var, API tokens and cloud credentials included, is cleared so it
can't leak in; name one with `--keep-env` to carry it through.

**Not visible at all:** `~/.ssh` (private keys always; the config too
without `--allow-ssh`), `~/.aws`, `~/.config/gcloud`,
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
  `ssh` through the proxy with a `ProxyCommand` in `~/.ssh/config` (which
  needs [`--allow-ssh`](#--allow-ssh-agent-forwarding): that flag mounts
  the config and forwards the key).

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
invisible, as with any agent forward), mounts `~/.ssh/config` and
`~/.ssh/known_hosts` read-only so `ssh` finds your host aliases and known
keys, and prints a warning. Without the flag none of `~/.ssh` is visible:
with no agent to use it, the config would only tell the session which
hosts, users and key files you have.

The warning is there because an agent signature can't be scoped to a
destination: for as long as the session runs it can ask your agent to
authenticate to *any* host it can reach, not only the git remote you had in
mind. Under the egress filter that's a short list — reaching an SSH host at
all needs `--allow-host` plus a `ProxyCommand` — but the capability is
wider than the use, so it's a deliberate choice rather than a default.

## `--keep-env` (passing a variable through)

The session starts from an empty environment: aye-buddy sets `HOME`,
`USER`, `PATH`, `TERM`, the locale vars and the cache pointers, and nothing
else survives. That's what keeps `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`
and the rest of your shell's environment out of reach.

`--keep-env NAME` carries one variable in with its host value:

```
aye-buddy --keep-env RUSTFLAGS --keep-env MAKEFLAGS
```

It takes a single name, not a `NAME=VALUE` pair, and it's repeatable. Whether
the value is a secret is your call: aye-buddy passes it through verbatim.

One caveat if it is one: the value travels as a `bwrap --setenv` argument, so
it's in the sandbox process's command line and any other user on the host can
read it out of `ps` for as long as the session runs. bwrap can take its whole
argv from a file descriptor instead (`--args FD`), which would keep it off the
command line, but aye-buddy doesn't do that today. On a machine you share, keep
secrets out of `--keep-env`.

## Limitations

- **Project write actions aren't restricted.** The session runs with claude's
  permission prompts skipped, so it can run destructive in-project
  commands or `git push`. The threat model is read-exfil and egress, not
  write protection.
- **Git worktrees and submodule working dirs are refused.** Their `.git`
  points outside the project directory, which the sandbox doesn't bind, so
  git would break inside. Run from the main checkout instead.
- **A repo overlapping `$HOME` or `~/.claude` is refused.** Both are
  mounted over in the sandbox — `$HOME` by a tmpfs, `~/.claude` by the
  state dir — and the project directory is bound over them, so a dotfiles
  repo in `~`, a versioned `~/.claude`, or a repo `~/.claude` symlinks into
  would mount the real thing back read-write. Keep the repo elsewhere
  below `$HOME`.
- **Project-scoped config writes fail.** The project's `.claude/` is
  read-only, so writes there — `.claude/settings.local.json` — fail
  in-session; edit project-scoped config on the host. A project `.claude`
  that is a symlink, or not a directory, is refused, since a read-only
  bind would expose a symlink's target instead of guarding it.
- **Host and sandbox state diverge.** A sandboxed session and a host-side
  `claude` in the same repo keep separate transcripts, memory and
  settings: `--continue` and `--resume` in the sandbox see only sandboxed
  sessions, and the other way round. A host-side change to settings,
  skills or plugins needs `--reseed`, which discards what a session
  added to the copied dirs; the rest of the config is mounted live, and
  read-only, so `/agents`, `/output-style:new`, `#` into the user
  `CLAUDE.md` and the like fail in-session: make those on the host. An
  in-session `git worktree add` still vanishes at exit: the checkout under
  `.claude/worktrees/` and its `.git/worktrees/` registration are
  overlays, while the branch and its commits persist in `.git`.
- **The credentials file is readable *and* writable in-session.** `claude`
  needs the OAuth token and has to be able to rewrite it on refresh, so the
  file is bound read-write; a payload runs under the same uid, so it can read
  the token — and replace it with one of its own, which a later host-side
  `claude` would then authenticate with. Closing the read would mean
  terminating TLS for `api.anthropic.com` at the proxy, against the
  no-interception design.
- **A host-side token refresh doesn't reach a running session.** The bind
  pins the file as it was at launch, and `claude` replaces it wholesale on
  refresh, so a rotation done on the host while a sandbox is up leaves that
  session holding a token the host has already retired. Writes go the other
  way fine — an in-session refresh or login lands on the host file, and
  aye-buddy creates an empty one first if you've never logged in. Don't run
  a host-side `claude` alongside a sandboxed one; restart the sandbox if you
  do.
- **API-key auth means the session can read the key.** A
  `/login`-managed key lives in `~/.claude.json`, which the session has a
  copy of. Reading it is unavoidable — billing against a key requires the
  key to be present. The copy is the sandbox's own, so a payload rewriting
  it, or pre-approving a key of its own through
  `customApiKeyResponses.approved`, affects later sandboxed runs of this
  project and no host run. Prefer an OAuth login.

## Tests

```
make test
```

Black-box tests for option parsing and the egress helpers (`t/`). The full
network mechanism needs real namespaces and is verified out-of-band by
`t/manual/egress-check.sh`; the worktree overlays likewise by
`t/manual/overlay-check.sh`, run in two phases around a real session (see its
header).

## Development

The seccomp denylists (`filter.bpf`, `filter-nested.bpf`) are committed blobs
generated from `gen-seccomp.c`; regenerate them with `make seccomp` after
editing the source. That also refreshes `seccomp.stamp`, a checksum of the
source the blobs were built from — `make check-stamp` verifies it and runs
first under `make test`, so a forgotten rebuild fails the tests on any
machine, no toolchain required.

## License

MIT — see [LICENSE](LICENSE).
