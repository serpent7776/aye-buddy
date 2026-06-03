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
escape, network egress filtering (the sandbox keeps full network access
for the Claude API and package installs), and anything the user runs
outside the wrapper.

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
- network (`--share-net`)
- a minimal environment subset — `PATH`, `HOME`, `USER`, `LOGNAME`,
  `TERM`, `LANG`, any `LC_*` you have set, `COLORTERM`, `NO_COLOR`, and
  `SSH_AUTH_SOCK`. Every other host env var (API tokens, cloud
  credentials, arbitrary shell exports) is cleared by `--clearenv` so it
  doesn't leak into the sandbox. If a session genuinely needs an extra
  variable, set it after `claude` starts or wire it into the wrapper.

Deliberately not bound: `~/.ssh/` private keys, `~/.aws`,
`~/.config/gcloud`, `~/.kube`, `~/.netrc`, browser profiles, password
stores, other projects under `$HOME`, `/home/<other-users>`, `/root`,
`/var`, `/srv`. `$HOME` starts as a fresh tmpfs and only the paths
listed above are mounted into it; everything else is invisible.

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
