# Black-box harness for aye-buddy's option parsing.
#
# Each run_aye() builds a throwaway world: a temp git repo to run inside, and a
# stub `bwrap`/`claude` first on PATH. The real aye-buddy runs unmodified; the
# stub bwrap prints the argv it was handed (one entry per line) so tests can
# assert on exactly what aye-buddy built and would have exec'd.
package AyeTest;
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use POSIX qw(dup2);
use Exporter 'import';

our @EXPORT = qw(run_aye bwrap_binds overlay_dests setenv_value setenv_list);

# Resolve the script under test relative to this file, not CWD (we chdir away).
my $AYE = abs_path(__FILE__ . '/../../../aye-buddy')
    or die "cannot locate aye-buddy";

sub _stub {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "stub $path: $!";
    # Shebang the real interpreter, not `env perl`: the child's PATH holds only
    # the stub dir, so `env` couldn't find perl there.
    print $fh "#!$^X\nuse strict; use warnings;\n$body\n";
    close $fh;
    chmod 0755, $path or die "chmod $path: $!";
}

# run_aye(@argv) -> hashref { out, err, exit, argv, root }
#   out/err : captured stdout/stderr of aye-buddy (the stub bwrap prints to out)
#   exit    : exit status (0 on a successful exec of the stub)
#   argv    : the stub bwrap's argv as an arrayref (aye-buddy's constructed call)
#   root    : the temp world, for asserting on what the run left on the "host"
# An optional leading hashref sets options; { no_repo => 1 } omits the .git marker
# so the run happens outside any repo, { no_ip => 1 } drops the ip stub so the
# net-filter dependency check can be exercised, { ssh_sock => 1 } listens on a
# unix socket and points SSH_AUTH_SOCK at it (aye-buddy requires a real -S path),
# { repo_name => NAME } names the repo dir something other than `repo`,
# { claude_link => PATH } makes ~/.claude a symlink to $root/PATH instead of a
# real dir, the shape a dotfiles manager leaves behind, { repo_claude_link =>
# PATH } does the same for the repo's own .claude and { repo_claude_file => 1 }
# plants a plain file there, { cache_file => 1 }
# plants a plain file where ~/.cache/aye-buddy would go, { claude_dirs =>
# [NAMES] } creates those dirs under ~/.claude, { claude_files => [NAMES] }
# plants plain files there instead, { bwrap_version => STRING }
# sets what the stub bwrap answers to --version (default: new enough),
# { bwrap_version_status => N } the exit status of that answer,
# { overlay_probe_status => N } / { sandbox_probe_status => N } the exit
# status of the startup overlay/control probes (bwrap argv ending in `true`).
sub run_aye {
    my $opts = ref $_[0] eq 'HASH' ? shift : {};
    my @args = @_;

    my $root = tempdir(CLEANUP => 1);
    my $repo = $opts->{repo_name} // 'repo';
    make_path("$root/bin", "$root/home", "$root/$repo");
    make_path("$root/$repo/.git") unless $opts->{no_repo};
    if (my $link = $opts->{claude_link}) {
        make_path("$root/$link");
        symlink "$root/$link", "$root/home/.claude" or die "symlink: $!";
    }
    else { make_path("$root/home/.claude") }
    if (my $link = $opts->{repo_claude_link}) {
        make_path("$root/$link");
        symlink "$root/$link", "$root/$repo/.claude" or die "symlink: $!";
    }
    if ($opts->{repo_claude_file}) {
        open my $fh, '>', "$root/$repo/.claude" or die "open: $!";
        close $fh;
    }
    make_path("$root/home/.claude/$_") for @{ $opts->{claude_dirs} // [] };
    for my $f (@{ $opts->{claude_files} // [] }) {
        open my $fh, '>', "$root/home/.claude/$f" or die "open: $!";
        close $fh;
    }
    if ($opts->{cache_file}) {
        make_path("$root/home/.cache");
        open my $fh, '>', "$root/home/.cache/aye-buddy" or die "open: $!";
        close $fh;
    }

    # Stub bwrap/pasta dump their argv; stub claude is only reached if real.
    # With egress filtering on (the default) aye-buddy execs pasta, whose argv
    # nests the whole bwrap command; with --no-net-filter it execs bwrap.
    # aye-buddy probes `bwrap --version` over a pipe before building the argv,
    # so the stub answers that first; the answer never lands in the out capture.
    my $bv  = quotemeta($opts->{bwrap_version} // 'bubblewrap 0.11.2');
    my $bvs = $opts->{bwrap_version_status} // 0;
    my $ops = $opts->{overlay_probe_status} // 0;
    my $sps = $opts->{sandbox_probe_status} // 0;
    _stub("$root/bin/bwrap",
          "if (\@ARGV == 1 && \$ARGV[0] eq '--version') { print \"$bv\\n\"; exit $bvs }\n"
        . "if (\@ARGV && \$ARGV[-1] eq 'true') { exit((grep { \$_ eq '--tmp-overlay' } \@ARGV) ? $ops : $sps) }\n"
        . 'print "$_\n" for @ARGV; exit 0;');
    _stub("$root/bin/pasta", 'print "$_\n" for @ARGV; exit 0;');
    _stub("$root/bin/claude", 'exit 0;');
    # Only aye-buddy's presence check looks for ip; the stub pasta never runs
    # aye-netns-seal, which is what would actually call it.
    _stub("$root/bin/ip", 'exit 0;') unless $opts->{no_ip};

    # Keep the listener in the parent so it outlives the exec'd child.
    my $agent_sock;
    if ($opts->{ssh_sock}) {
        require IO::Socket::UNIX;
        $agent_sock = IO::Socket::UNIX->new(Listen => 1, Local => "$root/agent.sock")
            or die "agent socket: $!";
    }

    my $outf = "$root/out";
    my $errf = "$root/err";

    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        # Child: isolated env, run inside the temp repo, capture std streams.
        $ENV{PATH} = "$root/bin";       # only our stubs; keep it hermetic
        $ENV{HOME} = "$root/home";
        $ENV{TMPDIR} = $root;           # proxy log lands here, cleaned with $root
        # Deterministic bwrap argv: no host agent unless a test asks for one.
        if ($agent_sock) { $ENV{SSH_AUTH_SOCK} = "$root/agent.sock" }
        else             { delete $ENV{SSH_AUTH_SOCK} }
        chdir "$root/$repo" or die "chdir: $!";
        open my $o, '>', $outf or die $!;
        open my $e, '>', $errf or die $!;
        dup2(fileno($o), 1) or die $!;
        dup2(fileno($e), 2) or die $!;
        exec { $^X } $^X, $AYE, @args;
        die "exec aye-buddy: $!";
    }
    waitpid $pid, 0;
    my $exit = $? >> 8;

    my $out = _slurp($outf);
    my $err = _slurp($errf);
    return {
        out  => $out,
        err  => $err,
        exit => $exit,
        argv => [ split /\n/, $out ],
        root => $root,
    };
}

sub _slurp {
    my ($f) = @_;
    open my $fh, '<', $f or return '';
    local $/;
    return scalar <$fh>;
}

# Extract the (src, dest) pairs for a given bwrap bind flag from a captured argv.
# e.g. bwrap_binds($r->{argv}, '--bind') -> ( [src, dest], ... )
sub bwrap_binds {
    my ($argv, $flag) = @_;
    my @out;
    for my $i (0 .. $#$argv) {
        next unless $argv->[$i] eq $flag;
        push @out, [ $argv->[$i + 1], $argv->[$i + 2] ];
    }
    return @out;
}

# The destinations of every --tmp-overlay in a captured argv.
sub overlay_dests {
    my ($argv) = @_;
    return map { $argv->[$_ + 1] } grep { $argv->[$_] eq '--tmp-overlay' } 0 .. $#$argv - 1;
}

# The last --setenv VALUE for $name in a captured argv, or undef if none.
sub setenv_value {
    my ($argv, $name) = @_;
    my $val;
    for my $i (0 .. $#$argv - 2) {
        next unless $argv->[$i] eq '--setenv' && $argv->[$i + 1] eq $name;
        $val = $argv->[$i + 2];
    }
    return $val;
}

# A newline-joined --setenv value (the LL_* lists) as a list. The stub prints
# one argv entry per line, so such a value fans out into the lines after the
# name; collect until the next flag.
sub setenv_list {
    my ($argv, $name) = @_;
    my ($i) = grep { $argv->[$_] eq '--setenv' && $argv->[$_ + 1] eq $name }
              0 .. $#$argv - 1;
    return () unless defined $i;
    my @vals;
    for my $j ($i + 2 .. $#$argv) {
        last if $argv->[$j] =~ /\A--/;
        push @vals, $argv->[$j];
    }
    return @vals;
}

1;
