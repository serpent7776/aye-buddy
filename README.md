# aye-buddy

Runs Claude Code on the local machine inside a `bwrap` sandbox so a
session can only see files that belong to the project you're working on.

## Threat model

A Claude Code session has tool access to the filesystem and runs shell
commands. Without isolation, any session can read SSH keys, browser
profiles, password stores, other projects' source, shell history,
`.netrc`, cloud SDK credentials, and personal documents — either because
the model decides those files are "relevant context", or because a
prompt injection in a fetched page, dependency README, or issue comment
tells it to exfiltrate.

`aye-buddy` defends against **read exfiltration**. Out of scope: kernel
escape and anything the user runs outside the wrapper.

It also filters **network egress** (on by default), which blunts the
reverse-shell class of attack — e.g. an injected instruction that runs a
"recovery" command which opens a shell to an attacker host. The session
reaches the network only through a bundled filtering proxy that permits a
small allowlist of hosts (the Claude API, common package registries, git
over HTTPS); everything else has no route out, so a raw-socket shell can't
connect. This is egress *control*, not *prevention* — see the caveats
under [Network egress filtering](#network-egress-filtering) — but it turns
"full machine compromise" into "a shell confined to the sandbox with no
way to phone home". Pass `--no-net-filter` to fall back to full network
access.

It also blocks one escape that filesystem isolation alone doesn't:
**terminal injection**. The session shares your controlling terminal, so
without protection it could use the `TIOCSTI` ioctl to push keystrokes
into your shell's input buffer — typing a command that runs after
`claude` exits, with none of the sandbox restrictions. `--new-session`
(setsid) gives the session a new session with no controlling terminal,
so `TIOCSTI` has no target. Linux 6.2+ also gates `TIOCSTI` behind the
`dev.tty.legacy_tiocsti` sysctl (off by default), but `--new-session`
closes it on older kernels too rather than relying on that.

## Requires

- `bwrap` (bubblewrap)
- `claude` (Claude Code CLI)
- `pasta` (from `passt`) — for the default egress filter; not needed with
  `--no-net-filter`
- a `git` or `jj` repository (the wrapper refuses to run outside one)

## Install

```
make install
```

Runs `install.sh`, which copies `aye-buddy` into the first of
`~/.local/bin` or `~/bin` that's on your `$PATH` (creating
`~/.local/bin` if neither is). It then asks whether to add a `claude`
shell function that forwards to `aye-buddy` — answer `y` and it appends
the function to `~/.zshrc` / `~/.bashrc` (POSIX) or writes
`~/.config/fish/functions/claude.fish` (fish), picked from your login
shell in `/etc/passwd`. The function uses `command` so running `command
claude` still reaches the real binary when you want to bypass the
sandbox. `make uninstall` removes the installed `aye-buddy` binary and
(for fish) the `claude.fish` function file; the `~/.zshrc` / `~/.bashrc`
block has to be removed by hand.

## Use

Run `aye-buddy` (or `claude`, if you installed the shell function) from
inside a project. All arguments are forwarded to `claude`, which is
invoked with:

- `--dangerously-skip-permissions` — claude's interactive per-tool
  permission prompts are redundant once everything outside the project
  is unreachable, and skipping them keeps the session usable.
- `--settings '{"sandbox":{"enabled":false}}'` — disables claude's
  built-in bash sandbox for just this invocation (without touching your
  persisted `settings.json`). The bwrap boundary is doing that job
  already; nesting a second bubblewrap inside the first adds friction
  (user-namespace edge cases, overhead) without meaningful
  defense-in-depth for the read-exfil threat model.
- `CLAUDE_CODE_SANDBOXED=1` (env) — tells claude the workspace trust
  decision was already made by the outer sandbox, skipping the trust
  dialog.

```
aye-buddy
aye-buddy -p "summarise this repo"
```

If you installed the `claude` shell function, `claude` and `claude -p
"..."` work the same way.

The project root is found by walking up from the current directory
until a `.git` or `.jj` entry appears. No `git` or `jj` process runs on
the host for this — `git rev-parse` would process the project's
`.git/config` before the sandbox exists, and config knobs like
`core.fsmonitor` could execute code on the host.

Paths inside the sandbox match host paths exactly (no `/work` rebind),
so error messages and stack traces open correctly in your host editor
and Claude's own per-project state stays coherent with host-run
sessions.

### `--bind` / `--bind-ro` (extra paths)

By default only the project root and a fixed set of `~/.claude` paths are
reachable. Pass `--bind PATH` (read-write) or `--bind-ro PATH`
(read-only) to expose an additional host path, mounted at the *same* path
inside the sandbox. The value may be attached with `=` (`--bind=PATH`).
Both are `aye-buddy` flags — they're stripped before the rest of the
arguments reach `claude` — and both are repeatable:

```
aye-buddy --bind-ro /data/refs --bind ~/scratch -p "compare against the refs"
```

Paths are resolved relative to the current directory and exposed by a
bwrap bind, so they work with or without `--allow-bwrap`. When the
Landlock layer is active they're added to its ruleset too (honouring the
read-only split); under `--allow-bwrap` Landlock is off for the whole
session (see below), leaving the bwrap bind as the only wall — as it is
for every other path. Symlinks are resolved, so a bind lands at its real
target. A missing, empty, or non-existent PATH is rejected up front
rather than silently binding the current directory or failing obscurely
inside bwrap. `aye-buddy`'s own flags must come before any arguments
meant for `claude`; an optional `--` separator ends `aye-buddy`'s flags
explicitly, so anything after it (even a literal `--allow-bwrap`) is
passed straight to `claude`. A misplaced `aye-buddy` flag after the
claude arguments is an error rather than being silently forwarded.

### `--allow-bwrap` (nested sandboxing)

By default the session can't run `bwrap` itself: the seccomp denylist
blocks the `unshare`/`clone`/`mount`/`pivot_root` syscalls bubblewrap
needs (so a session can't spin up new namespaces), and the Landlock
ruleset would deny the inner sandbox's fresh mounts anyway. Pass
`--allow-bwrap` (an `aye-buddy` flag — it's stripped before the rest of
the arguments reach `claude`) to let the session build its own inner
sandboxes:

```
aye-buddy --allow-bwrap -p "run the test suite under bwrap"
```

It is opt-in because it widens the trust boundary:

- the relaxed seccomp blob (`filter-nested.bpf`) re-allows only the five
  calls bwrap actually uses to build a sandbox — `unshare`, `mount`,
  `umount2`, `pivot_root`, and `clone` with namespace flags. Everything
  else stays denied, including the new mount API (`fsopen`, `open_tree`,
  `move_mount`, …), `setns`, `chroot`, `ptrace`, `bpf`, the keyring, and
  module loading.
- **Landlock is turned off for the session.** A nested `bwrap` mounts a
  fresh tmpfs and `pivot_root`s into a new root; those inodes sit beneath
  no path in the ruleset, so Landlock would block the inner sandbox. The
  bwrap mount-namespace allowlist is then the only outer filesystem wall
  — still the same set of paths under "What the sandbox sees", just
  without the second Landlock backstop.

The host kernel must permit nested unprivileged user namespaces (the
default where `bwrap` already works unprivileged). `aye-buddy` prints a
warning when the flag is active so the reduced isolation isn't silent.

## What the sandbox sees

Read-write:

- the project root (only this one — no other directory under `$HOME` is
  reachable)
- `~/.claude/` (sessions, projects, todos, history, file-history,
  backups, caches, telemetry, OAuth credentials, …) — claude actively
  writes to many subpaths and the bind is rw to keep `--continue` and
  similar state-driven features working
- `~/.claude.json`

Read-only (overlaid on top of the rw `~/.claude` bind to block the
code-execution vectors a later host-side `claude` would load):

- `~/.claude/settings.json`, `settings.local.json` (hook config)
- `~/.claude/commands/` (custom slash commands)
- `~/.claude/agents/` (subagent definitions)
- `~/.claude/plugins/` (plugins, which can register hooks/commands)
- `~/.claude/hooks/`
- `~/.claude/scripts/` (personal scripts referenced by hooks,
  statusline, custom commands — put your `statusline-command.pl` and
  similar here, then point your settings at the `scripts/` path)
- `~/.claude/mcp.json`, `.mcp.json` (MCP server commands)

Also read-only:

- `/usr`, `/etc`, `/opt`, `/nix` — host-installed tools just work; no
  image rebuild when you install something new on the host
- `.git/hooks`, `.git/config`, `.git/modules/` inside the project
- `~/.gitconfig`, `~/.config/git`, `~/.ssh/config`, `~/.ssh/known_hosts`

Forwarded:

- the SSH agent socket if `SSH_AUTH_SOCK` is set (signs for git/ssh
  without exposing key material)
- network — filtered through the egress proxy by default (see below), or
  the host network directly under `--no-net-filter`
- a minimal environment subset — `PATH`, `HOME`, `USER`, `LOGNAME`,
  `TERM`, `LANG`, any `LC_*` you have set, `COLORTERM`, `NO_COLOR`, and
  `SSH_AUTH_SOCK`. Every other host env var (API tokens, cloud
  credentials, arbitrary shell exports) is cleared by `--clearenv` so it
  doesn't leak into the sandbox. If a session genuinely needs an extra
  variable, set it after `claude` starts or wire it into the wrapper.
- `DISABLE_TELEMETRY=1` and `DISABLE_ERROR_REPORTING=1` are set to stop
  claude's non-essential telemetry/error egress (Datadog/Statsig/Sentry)
  at the source. The narrow vars are used deliberately — not the broad
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, which would also disable the
  auto-updater's security patches, feature flags, and TUI mouse clicks.
  Anything that still dials out is caught by the egress allowlist anyway.

Deliberately not bound: `~/.ssh/` private keys, `~/.aws`,
`~/.config/gcloud`, `~/.kube`, `~/.netrc`, browser profiles, password
stores, other projects under `$HOME`, `/home/<other-users>`, `/root`,
`/var`, `/srv`. `$HOME` starts as a fresh tmpfs and only the paths
listed above are mounted into it; everything else is invisible.

## Network egress filtering

On by default. The sandbox runs in a network namespace whose only uplink
is a bundled filtering proxy (`aye-proxy`), so every outbound connection
is either an allowlisted HTTPS host tunnelled through the proxy or has no
route at all. A reverse shell — a raw socket to an attacker host — falls
in the second bucket and simply cannot connect.

How it fits together: aye-buddy starts `aye-proxy` on the host, then
launches the sandbox under `pasta` (`pasta → aye-net-helper → bwrap →
claude`). `pasta` gives the namespace a userspace uplink; `aye-net-helper`
tightens the netns route to a single host route to the gateway — so only
the proxy is reachable, and both the wider internet and same-subnet (LAN)
hosts lose their route — then points `HTTP(S)_PROXY` at it. After
tightening it probes the proxy and, if reachability broke, reverts to the
looser default-route-only routing so the session still works. `pasta`
must be the parent of `bwrap` because it needs `sethostname`/namespace
syscalls that `bwrap`'s seccomp denies — so it runs before the filter is
installed.

`--allow-subnet` keeps same-subnet hosts reachable (see the residual note
below) — the escape hatch for a workload that needs a LAN host, or a setup
where the tighter routing is a problem.

The builtin allowlist covers the Claude API and telemetry, the major
package registries (npm, PyPI, crates.io, Go), and git over HTTPS. Add
more with `--allow-host`:

```
aye-buddy --allow-host git.internal.corp --allow-host registry.example:443
```

`--allow-host HOST[:PORT]` is repeatable; a port-less host permits 80/443,
`HOST:PORT` permits exactly that port. It's an `aye-buddy` flag (stripped
before `claude`, same placement rules as `--bind`).

Note that WebSearch runs server-side on Anthropic's infrastructure, so it
keeps working regardless; only WebFetch (which fetches from your machine)
is subject to the allowlist, and reaching an off-list site returns a
proxy `403`.

**This is egress control, not egress prevention — know the residual
risks:**

- **Exfil through allowed hosts.** Anything you allowlist is a two-way
  channel. Data can still leave via, say, a GitHub gist or an allowed
  package registry. Keep the list minimal.
- **No TLS interception.** The proxy allows a `CONNECT` by its hostname
  without terminating TLS, so SNI spoofing / domain fronting can reach an
  off-list host that shares infrastructure with an allowed one.
- **Same-subnet hosts — tightened, but check your mode.** By default the
  route is pinned to the gateway only, so LAN hosts have no route either.
  Two caveats: `--allow-subnet` deliberately re-opens the subnet, and if
  the tight routing can't reach the proxy on your setup, `aye-net-helper`
  auto-reverts to the looser routing (LAN reachable) and warns — so under
  those conditions the LAN residual is back. `t/manual/egress-check.sh`
  verifies which mode actually took effect.
- **SSH git needs a hole.** SSH remotes don't traverse an HTTP proxy;
  prefer HTTPS remotes, or allowlist the git host — a raw-TCP lane for
  `HOST:22` is not wired yet (`--allow-host` currently feeds the HTTPS
  proxy allowlist).

`--no-net-filter` turns all of this off and restores full `--share-net`
network access — useful for debugging or workloads the allowlist can't
express yet.

## Tests

```
make test
```

Black-box tests for `aye-buddy`'s option parsing (`t/`). Each test runs
the real script against stub `bwrap`/`pasta` placed first on a hermetic
`PATH`, then asserts on the argv the script would have `exec`'d — so the
actual flag parsing, `--` handling, path resolution, and forwarding are
exercised end to end without launching a real sandbox. `aye-proxy` has
its own loopback tests; the full egress mechanism (which needs real
namespaces) is verified out-of-band by `t/manual/egress-check.sh`.

## Limitations

- **Git worktrees and submodule working dirs are refused.** In a linked
  worktree (or a submodule's working dir) `.git` is a *file* pointing to
  a gitdir outside the directory — under the main repo's
  `.git/worktrees/<name>` plus the shared common `.git`. The wrapper only
  binds the project directory, so that gitdir is unreachable and every
  git command inside the sandbox fails. `aye-buddy` detects this (`.git`
  is a file, not a directory) and refuses to launch with a message
  pointing you at the main checkout. Run from there instead.
- **Submodule updates fail inside the sandbox.** `.git/modules/` is
  bound read-only to stop a session from planting hooks or config inside
  a submodule's git dir that the host would later execute. Run
  `git submodule update --init` on the host, outside the wrapper.
- **`.git/hooks` and `.git/config` are read-only** for the same reason
  (`core.fsmonitor`, `core.sshCommand`, bang-aliases, commit hooks).
  Configure these on the host before starting a session.
- **`~/.claude/settings.json`, `commands/`, `agents/`, `plugins/`,
  `hooks/`, `scripts/`, and `mcp.json` are read-only** so a
  session cannot inject hooks or commands that a later host-side
  `claude` invocation would execute. The rest of `~/.claude/` is rw so
  state-driven features like `--continue` work. If one of those ro paths
  doesn't exist on launch, the sandbox doesn't create a placeholder for
  it — the path falls through to rw. Create empty ones on the host if
  you want enforcement before any of them have been set up.
  - A consequence: commands that persist to `settings.json` fail inside
    the sandbox. `/effort` (changing the effort level) writes to
    `settings.json` and errors with `EROFS: read-only file system`. Set
    the effort level on the host before launching, or pass it per
    invocation. The same applies to any setting that `claude` would save
    back to `settings.json`.
- **Network is unrestricted.** Outbound traffic is not filtered.
- **No protection against running `claude` directly.** Discoverability
  of `aye-buddy` is the only mitigation against the user bypassing it.
- **`~/.claude` is shared with host-run sessions**, so a session running
  in project A can read transcripts from project B under
  `~/.claude/projects/<other-slug>/`. Accepted trade for unified history
  with host-run Claude.
- **OAuth refresh race.** Running a host `claude` and a sandboxed
  `aye-buddy` session simultaneously can invalidate each other's
  refresh token. Don't run both at the same time.
