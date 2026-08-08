package AyeSeccomp;
# Shared seccomp-blob setup for --net-filter / --no-net-filter paths
use strict;
use warnings;
use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);
use Exporter qw(import);

our @EXPORT_OK = qw(arm_seccomp SECCOMP_FD_TOKEN PROXY_TOKEN);

# Placeholders aye-buddy bakes into the bwrap argv; rewritten just before exec.
# One home for each token so a bake site and its rewrite can't drift apart.
use constant SECCOMP_FD_TOKEN => '@@AYE_SECCOMP_FD@@';
use constant PROXY_TOKEN      => '@@AYE_PROXY@@';

# Open the blob, clear close-on-exec (Perl opens fds cloexec) so the fd survives
# the exec into bwrap, and rewrite the SECCOMP_FD_TOKEN that follows --seccomp in
# @$argv to that fd number. Anchored on the flag rather than scanning for the
# token, so a --setenv value that happens to equal it can't take the rewrite.
# Returns the open handle: keep it in scope until exec or the kernel closes the
# fd out from under bwrap. Dies with a trailing newline (so callers get a clean
# message, no "at line" noise) if the blob can't be opened or prepared.
sub arm_seccomp {
    my ($argv, $blob) = @_;
    open(my $fh, '<', $blob) or die "open seccomp blob $blob: $!\n";
    my $flags = fcntl($fh, F_GETFD, 0);
    defined $flags or die "F_GETFD on seccomp blob: $!\n";
    fcntl($fh, F_SETFD, $flags & ~FD_CLOEXEC) or die "clear cloexec on seccomp blob: $!\n";
    my $fd = fileno($fh);
    for my $i (0 .. $#$argv - 1) {
        next unless $argv->[$i] eq '--seccomp'
                 && $argv->[$i + 1] eq SECCOMP_FD_TOKEN;
        $argv->[$i + 1] = $fd;
        return $fh;
    }
    die "seccomp fd placeholder not found in argv\n";
}

1;
