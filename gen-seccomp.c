/*
 * gen-seccomp.c — generate the seccomp-bpf blob that aye-buddy feeds to
 * `bwrap --seccomp`. Build-time only: compile once, run once, commit the
 * resulting filter.bpf. The sandbox itself needs no compiler or libseccomp at
 * runtime — bwrap loads the precompiled cBPF program directly.
 *
 *   cc -o gen-seccomp gen-seccomp.c -lseccomp && ./gen-seccomp filter.bpf
 *
 * Policy: DENYLIST (default ALLOW, deny a fixed set). An interactive coding
 * agent spawns arbitrary toolchains, so a strict allowlist would SIGSYS
 * something eventually; a denylist removes the high-risk / escape-relevant
 * syscalls while leaving normal operation untouched. This is the syscall-axis
 * companion to the Landlock filesystem ruleset (see ll-helper): Landlock
 * guards which inodes can be opened; seccomp guards which kernel entry points
 * can be called at all — i.e. it protects the sandbox's own integrity by
 * denying the primitives an escape would use.
 *
 * bwrap applies this to the *payload* after it has finished building the
 * sandbox, so denying the namespace/mount syscalls here does NOT interfere
 * with bwrap's own setup (which needs unshare/mount/pivot_root).
 *
 * Denied calls return an errno rather than killing the process (SIGSYS), so a
 * tool that probes for a feature degrades instead of crashing. Feature-probe
 * style calls return ENOSYS ("not implemented") so callers cleanly fall back;
 * clearly-privileged calls return EPERM.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <seccomp.h>
#include <linux/sched.h>   /* CLONE_NEW* */

/* Privileged / escape-relevant syscalls a sandboxed agent never legitimately
 * needs. EPERM. */
static const char *deny_eperm[] = {
    "chroot", "setns",
    "move_mount", "open_tree", "fsopen", "fsconfig", "fsmount", "fspick",
    "mount_setattr",
    /* handle-based open: resolves a file by inode/NFS handle, bypassing
     * path-based access control (the "Shocker" container escape) and the one
     * primitive that could sidestep Landlock's path matching. */
    "open_by_handle_at",
    /* cross-process inspection / injection */
    "ptrace", "process_vm_readv", "process_vm_writev", "kcmp", "pidfd_getfd",
    /* x86 raw I/O-port access (CAP_SYS_RAWIO); nothing in the sandbox uses it */
    "ioperm", "iopl",
    /* UTS identity. We don't --unshare-uts, so deny outright as defense in
     * depth (the userns wouldn't own the host UTS namespace anyway). */
    "sethostname", "setdomainname",
    /* global filesystem monitoring (CAP_SYS_ADMIN); dev watchers use inotify */
    "fanotify_init", "fanotify_mark",
    /* kernel code / module loading */
    "kexec_load", "kexec_file_load",
    "init_module", "finit_module", "delete_module",
    /* kernel keyring */
    "add_key", "request_key", "keyctl",
    /* misc privileged machine-state knobs (also gated by no_new_privs/caps,
     * but cheap to deny outright) */
    "swapon", "swapoff", "reboot", "acct", "quotactl",
    "settimeofday", "clock_settime", "clock_adjtime", "adjtimex",
    NULL,
};

/* Denied by default, RE-ALLOWED in the --allow-nested-bwrap variant. */
static const char *deny_nest[] = {
    "unshare", "mount", "umount2", "pivot_root",
    NULL,
};

/* Feature-probe style syscalls: large kernel attack surfaces that callers
 * already gate behind a runtime probe. ENOSYS makes them transparently fall
 * back (e.g. libuv → threadpool, glibc clone3 → clone). */
static const char *deny_enosys[] = {
    "bpf", "perf_event_open", "userfaultfd",
    "io_uring_setup", "io_uring_enter", "io_uring_register",
    /* obsolete oprofile call, removed in kernels >= 5.16; pure surface cut */
    "lookup_dcookie",
    NULL,
};

/* Arches the one committed blob covers. A seccomp filter dispatches on
 * data.arch first; any arch NOT listed here falls through to the default action
 * (ALLOW) — i.e. the sandbox silently does nothing on it. The build host's own
 * arch is irrelevant: libseccomp resolves every syscall from its static tables,
 * so an x86_64 box emits correct rules for all of these. Compat ABIs (X86/X32
 * under x86_64, ARM under aarch64) are listed so a denied call can't sneak in
 * through a compat entry point.
 *
 * Deliberately omitted: s390x (and other arches that reorder syscall args).
 * libseccomp does NOT remap argument indices across arches, and the clone-flags
 * rule below reads arg0 — correct here, but on s390x clone's flags are arg1, so
 * a merged rule would mis-filter. Better to leave those arches out (fail open,
 * caught by aye-buddy's runtime arch guard) than ship a wrong clone filter. */
static const uint32_t target_arches[] = {
    SCMP_ARCH_X86_64, SCMP_ARCH_X86, SCMP_ARCH_X32,
    SCMP_ARCH_AARCH64, SCMP_ARCH_ARM,
    SCMP_ARCH_PPC64LE,
    SCMP_ARCH_RISCV64,
#ifdef SCMP_ARCH_LOONGARCH64
    SCMP_ARCH_LOONGARCH64,
#endif
};

/* clone() namespace-creation flags. We allow clone() for threads/processes but
 * deny it when any new-namespace flag is set — the remaining way to spin up a
 * fresh user/mount namespace once unshare/setns are blocked. One masked rule
 * per flag (seccomp can read clone's scalar flags arg; arg0 on every arch in
 * target_arches[]). */
static const unsigned long clone_ns_flags[] = {
    CLONE_NEWNS, CLONE_NEWUSER, CLONE_NEWPID, CLONE_NEWNET,
    CLONE_NEWUTS, CLONE_NEWIPC, CLONE_NEWCGROUP,
#ifdef CLONE_NEWTIME
    CLONE_NEWTIME,
#endif
    0,
};

static int deny(scmp_filter_ctx ctx, const char *name, uint32_t action)
{
    int nr = seccomp_syscall_resolve_name(name);
    if (nr == __NR_SCMP_ERROR) {
        /* Unknown on this libseccomp/arch — skip rather than abort. */
        fprintf(stderr, "gen-seccomp: note: unknown syscall '%s', skipping\n", name);
        return 0;
    }
    int rc = seccomp_rule_add(ctx, action, nr, 0);
    if (rc < 0)
        fprintf(stderr, "gen-seccomp: warn: rule add for '%s': %s\n",
                name, strerror(-rc));
    return rc;
}

int main(int argc, char **argv)
{
    /* --allow-nested-bwrap re-allows the mount/namespace syscalls (deny_nest[]
     * and clone's namespace flags) so the sandboxed agent can run bwrap itself.
     * Everything else stays denied. */
    int allow_nested_bwrap = 0, bad = 0;
    const char *out = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--allow-nested-bwrap")) allow_nested_bwrap = 1;
        else if (!out)                                out = argv[i];
        else                                          bad = 1;
    }
    if (!out || bad) {
        fprintf(stderr, "usage: %s [--allow-nested-bwrap] <output.bpf>\n", argv[0]);
        return 2;
    }

    /* Default ALLOW; we subtract from there. */
    scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);
    if (!ctx) {
        fprintf(stderr, "gen-seccomp: seccomp_init failed\n");
        return 1;
    }

    /* Cover every target arch, not just the build host's. seccomp_init() has
     * already added the native arch; re-adding it returns -EEXIST, ignored. */
    for (size_t i = 0; i < sizeof target_arches / sizeof *target_arches; i++) {
        int rc = seccomp_arch_add(ctx, target_arches[i]);
        if (rc < 0 && rc != -EEXIST)
            fprintf(stderr, "gen-seccomp: warn: arch add 0x%x: %s\n",
                    target_arches[i], strerror(-rc));
    }

    for (const char **p = deny_eperm;  *p; p++) deny(ctx, *p, SCMP_ACT_ERRNO(EPERM));
    for (const char **p = deny_enosys; *p; p++) deny(ctx, *p, SCMP_ACT_ERRNO(ENOSYS));

    /* clone3 passes its flags inside a struct (a pointer seccomp can't read),
     * so it can't be filtered by flag — force ENOSYS so callers fall back to
     * clone(), which we *can* filter below. (bwrap's raw_clone uses SYS_clone.) */
    deny(ctx, "clone3", SCMP_ACT_ERRNO(ENOSYS));

    if (!allow_nested_bwrap) {
        for (const char **p = deny_nest; *p; p++) deny(ctx, *p, SCMP_ACT_ERRNO(EPERM));

        int clone_nr = seccomp_syscall_resolve_name("clone");
        if (clone_nr != __NR_SCMP_ERROR) {
            for (const unsigned long *f = clone_ns_flags; *f; f++) {
                int rc = seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), clone_nr, 1,
                             SCMP_A0(SCMP_CMP_MASKED_EQ, *f, *f));
                if (rc < 0)
                    fprintf(stderr, "gen-seccomp: warn: clone flag 0x%lx: %s\n",
                            *f, strerror(-rc));
            }
        }
    }

    FILE *fp = fopen(out, "wb");
    if (!fp) { perror("gen-seccomp: fopen"); seccomp_release(ctx); return 1; }
    int rc = seccomp_export_bpf(ctx, fileno(fp));
    if (rc < 0) {
        fprintf(stderr, "gen-seccomp: export: %s\n", strerror(-rc));
        fclose(fp); seccomp_release(ctx); return 1;
    }
    fclose(fp);
    seccomp_release(ctx);
    fprintf(stderr, "gen-seccomp: wrote %s%s\n", out,
            allow_nested_bwrap ? " (nested-bwrap variant)" : "");
    return 0;
}
