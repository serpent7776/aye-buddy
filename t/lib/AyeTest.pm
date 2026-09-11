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
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use POSIX qw(dup2);
use Exporter 'import';

our @EXPORT = qw(run_aye bwrap_binds overlay_dests setenv_value setenv_list state_name state_dir);

# Resolve the script under test relative to this file, not CWD (we chdir away).
my $AYE = abs_path(__FILE__ . '/../../../aye-buddy')
    or die "cannot locate aye-buddy";
# Found now, before any test touches PATH.
my %TOOL;
for my $tool (qw(cp chmod)) {
    ($TOOL{$tool}) = grep { -x $_ } map { "$_/$tool" } split /:/, $ENV{PATH};
    defined $TOOL{$tool} or die "no $tool on PATH";
}

sub _stub {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "stub $path: $!";
    # Shebang the real interpreter, not `env perl`: the child's PATH holds only
    # the stub dir, so `env` couldn't find perl there.
    print $fh "#!$^X\nuse strict; use warnings;\n$body\n";
    close $fh;
    chmod 0755, $path or die "chmod $path: $!";
}

# run_aye(@argv) -> hashref { out, err, exit, argv, fds, root }
#   out/err : captured stdout/stderr of aye-buddy (the stub bwrap prints to out)
#   exit    : exit status (0 on a successful exec of the stub)
#   argv    : the stub bwrap's argv as an arrayref (aye-buddy's constructed call)
#   fds     : what the launched stub's open fds point at, as an arrayref
#   root    : the temp world, for asserting on what the run left on the "host"
# An optional leading hashref sets options; { no_repo => 1 } omits the .git marker
# so the run happens outside any repo, { no_ip => 1 } drops the ip stub so the
# net-filter dependency check can be exercised, { ssh_sock => 1 } listens on a
# unix socket and points SSH_AUTH_SOCK at it (aye-buddy requires a real -S path),
# { repo_name => NAME } names the repo dir something other than `repo`,
# { claude_link => PATH } makes ~/.claude a symlink to $root/PATH instead of a
# real dir, the shape a dotfiles manager leaves behind, { repo_claude_link =>
# PATH } does the same for the repo's own .claude and { repo_claude_file => 1 }
# plants a plain file there, { repo_claude_dirs => [NAMES] } creates those
# dirs under the repo's .claude, { cache_file => 1 }
# plants a plain file where ~/.cache/aye-buddy would go, { claude_dirs =>
# [NAMES] } creates those dirs under ~/.claude, { claude_files => [NAMES] }
# plants plain files there instead, { files => { PATH => CONTENT } } writes
# those files under $root (@ROOT@ in CONTENT becomes $root), { dirs => [PATH] }
# creates those dirs under $root, { modes => { PATH => MODE } } chmods those,
# { links => { PATH => TARGET } } makes those symlinks under $root (TARGET
# relative to the link's dir unless absolute), { state_link => PATH } makes
# this project's sandbox state dir a symlink to $root/PATH, { bwrap_version
# => STRING } sets what the stub bwrap answers to --version (default: new
# enough), { bwrap_version_status => N } the exit status of that answer,
# { overlay_probe_status => N } / { lower_probe_status => N } /
# { sandbox_probe_status => N } the exit status of the startup
# kernel-overlay/lower-layer/control probes (bwrap argv ending in `true`),
# { bwrap_status => N } the exit status of the launched stub (bwrap or pasta),
# { config_dir => NAME } creates $root/NAME and points CLAUDE_CONFIG_DIR at
# it ({ config_dir_absent => 1 } points without creating), { state_home =>
# NAME } points XDG_STATE_HOME at $root/NAME, { env => { NAME => VALUE } }
# sets those vars verbatim in aye-buddy's environment, and { root => DIR }
# runs in the world an earlier run returned instead of a fresh one, so what
# that run left on the "host" is still there.
sub run_aye {
    my $opts = ref $_[0] eq 'HASH' ? shift : {};
    my @args = @_;

    my $root = $opts->{root} // tempdir(CLEANUP => 1);
    my $repo = $opts->{repo_name} // 'repo';
    make_path("$root/bin", "$root/home", "$root/$repo");
    make_path("$root/$repo/.git") unless $opts->{no_repo};
    if (my $link = $opts->{claude_link}) {
        make_path("$root/$link");
        symlink "$root/$link", "$root/home/.claude" or die "symlink: $!";
    }
    else { make_path("$root/home/.claude") }
    make_path("$root/$opts->{config_dir}") if defined $opts->{config_dir} && !$opts->{config_dir_absent};
    if (my $link = $opts->{repo_claude_link}) {
        make_path("$root/$link");
        symlink "$root/$link", "$root/$repo/.claude" or die "symlink: $!";
    }
    if ($opts->{repo_claude_file}) {
        open my $fh, '>', "$root/$repo/.claude" or die "open: $!";
        close $fh;
    }
    make_path("$root/$repo/.claude/$_") for @{ $opts->{repo_claude_dirs} // [] };
    make_path("$root/home/.claude/$_") for @{ $opts->{claude_dirs} // [] };
    if (my $link = $opts->{state_link}) {
        my $state_root = "$root/home/.local/state/aye-buddy/claude";
        make_path("$root/$link", $state_root);
        symlink "$root/$link", "$state_root/" . state_name(abs_path("$root/$repo"))
            or die "symlink: $!";
    }
    for my $f (@{ $opts->{claude_files} // [] }) {
        open my $fh, '>', "$root/home/.claude/$f" or die "open: $!";
        close $fh;
    }
    make_path("$root/$_") for @{ $opts->{dirs} // [] };
    for my $f (sort keys %{ $opts->{files} // {} }) {
        (my $content = $opts->{files}{$f}) =~ s/\@ROOT\@/$root/g;
        make_path(dirname("$root/$f"));
        open my $fh, '>', "$root/$f" or die "open $f: $!";
        print $fh $content;
        close $fh;
    }
    for my $l (sort keys %{ $opts->{links} // {} }) {
        make_path(dirname("$root/$l"));
        symlink $opts->{links}{$l}, "$root/$l" or die "symlink $l: $!";
    }
    for my $f (sort keys %{ $opts->{modes} // {} }) {
        chmod $opts->{modes}{$f}, "$root/$f" or die "chmod $f: $!";
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
    # The overlay probes are told apart by their lower: the repo (holds the
    # .git marker) for the real one, an empty tempdir for the kernel one.
    my $bv  = quotemeta($opts->{bwrap_version} // 'bubblewrap 0.11.2');
    my $bvs = $opts->{bwrap_version_status} // 0;
    my $ops = $opts->{overlay_probe_status} // 0;
    my $lps = $opts->{lower_probe_status} // 0;
    my $sps = $opts->{sandbox_probe_status} // 0;
    my $bws = $opts->{bwrap_status} // 0;
    # What the launched stub inherited: every fd's target, one per line, so a
    # test can assert on what aye-buddy let through to the session.
    my $fds = "opendir my \$d, '/proc/self/fd' or die \$!;\n"
            . "open my \$f, '>>', '$root/fds' or die \$!;\n"
            . "print \$f map { (readlink(\"/proc/self/fd/\$_\") // '?') . \"\\n\" } grep { /\\A\\d+\\z/ } readdir \$d;\n";
    _stub("$root/bin/bwrap",
          "if (\@ARGV == 1 && \$ARGV[0] eq '--version') { print \"$bv\\n\"; exit $bvs }\n"
        . "if (\@ARGV && \$ARGV[-1] eq 'true') {\n"
        . "  my \@src = map { \$ARGV[\$_ + 1] } grep { \$ARGV[\$_] eq '--overlay-src' } 0 .. \$#ARGV - 1;\n"
        . "  exit(!\@src ? $sps : (grep { -e \"\$_/.git\" || -d \"\$_/.jj\" } \@src) ? ($lps || $ops) : $ops) }\n"
        . $fds
        . "print \"\$_\\n\" for \@ARGV; exit $bws;");
    _stub("$root/bin/pasta", $fds . "print \"\$_\\n\" for \@ARGV; exit $bws;");
    # The seed copy runs the real cp and chmod; the only non-stubs on the
    # child's PATH.
    for my $tool (qw(cp chmod)) {
        next if -e "$root/bin/$tool";
        symlink $TOOL{$tool}, "$root/bin/$tool" or die "symlink $tool: $!";
    }
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
    unlink "$root/fds";    # a reused world holds the previous run's

    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        # Child: isolated env, run inside the temp repo, capture std streams.
        $ENV{PATH} = "$root/bin";       # only our stubs; keep it hermetic
        $ENV{HOME} = "$root/home";
        $ENV{TMPDIR} = $root;           # proxy log lands here, cleaned with $root
        # The host user's own state root must not leak into the runs.
        delete $ENV{CLAUDE_CONFIG_DIR};
        $ENV{CLAUDE_CONFIG_DIR} = "$root/$opts->{config_dir}" if defined $opts->{config_dir};
        # Likewise the host user's state root.
        delete $ENV{XDG_STATE_HOME};
        $ENV{XDG_STATE_HOME} = "$root/$opts->{state_home}" if defined $opts->{state_home};
        $ENV{$_} = $opts->{env}{$_} for keys %{ $opts->{env} // {} };
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
        fds  => [ split /\n/, _slurp("$root/fds") ],
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

# The name aye-buddy gives a project's sandbox state dir: '/' becomes '-',
# '-' becomes '__' and '_' becomes '_-'. The tests that pin the rule spell the
# expected name out; this is for the ones that only need to find the dir.
sub state_name {
    my ($path) = @_;
    $path =~ s{([/_-])}{ $1 eq '/' ? '-' : $1 eq '-' ? '__' : '_-' }ge;
    return $path;
}

# The host dir a captured run mounts as the session's claude state dir: the
# source of the rw bind at CLAUDE_CONFIG_DIR, or ~/.claude. undef if none.
sub state_dir {
    my ($r) = @_;
    my $dest = setenv_value($r->{argv}, 'CLAUDE_CONFIG_DIR')
            // setenv_value($r->{argv}, 'HOME') . '/.claude';
    my ($b) = grep { $_->[1] eq $dest } bwrap_binds($r->{argv}, '--bind');
    return $b ? $b->[0] : undef;
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
