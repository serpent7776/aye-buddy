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

our @EXPORT = qw(run_aye bwrap_binds);

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

# run_aye(@argv) -> hashref { out, err, exit, argv }
#   out/err : captured stdout/stderr of aye-buddy (the stub bwrap prints to out)
#   exit    : exit status (0 on a successful exec of the stub)
#   argv    : the stub bwrap's argv as an arrayref (aye-buddy's constructed call)
# An optional leading hashref sets options; { no_repo => 1 } omits the .git marker
# so the run happens outside any repo.
sub run_aye {
    my $opts = ref $_[0] eq 'HASH' ? shift : {};
    my @args = @_;

    my $root = tempdir(CLEANUP => 1);
    make_path("$root/home/.claude", "$root/bin");
    make_path("$root/repo/.git") unless $opts->{no_repo};
    make_path("$root/repo");

    # Stub bwrap dumps its argv; stub claude is only reached if bwrap were real.
    _stub("$root/bin/bwrap", 'print "$_\n" for @ARGV; exit 0;');
    _stub("$root/bin/claude", 'exit 0;');

    my $outf = "$root/out";
    my $errf = "$root/err";

    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        # Child: isolated env, run inside the temp repo, capture std streams.
        $ENV{PATH} = "$root/bin";       # only our stubs; keep it hermetic
        $ENV{HOME} = "$root/home";
        delete $ENV{SSH_AUTH_SOCK};     # keep the bwrap argv deterministic
        chdir "$root/repo" or die "chdir: $!";
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

1;
