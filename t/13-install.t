use strict;
use warnings;
use Test2::V0;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);

# Exercises install.sh and `make uninstall` against a throwaway $HOME, so the
# real host is never touched. It's pure filesystem work — no bwrap/pasta/root —
# so it runs the same on the host or inside an aye-buddy sandbox.
my $ROOT = abs_path(__FILE__ . '/../..') or die "cannot locate project root";
my $INSTALL = "$ROOT/install.sh";
-f $INSTALL or die "install.sh missing at $INSTALL";

# What install.sh should drop in libexec, split by expected mode class.
my @exec = qw(aye-buddy aye-landlock aye-proxy aye-netns-seal);
my @data = qw(AyeSeccomp.pm filter.bpf filter-nested.bpf);

sub mode_of { (stat $_[0])[2] & oct('7777') }

# Run @cmd in a child with HOME pointed at a throwaway dir and stdin closed (so
# install.sh takes the non-tty path and never edits an rc file). Returns the
# combined output and exit code.
sub run_env {
    my ($root, $home, $on_path, @cmd) = @_;
    my $log = "$root/log";
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        $ENV{HOME} = $home;
        $ENV{PATH} = $on_path ? "$on_path:$ENV{PATH}" : $ENV{PATH};
        open STDIN,  '<', '/dev/null' or die $!;
        open STDOUT, '>', $log        or die $!;
        open STDERR, '>&', \*STDOUT    or die $!;
        exec @cmd;
        die "exec @cmd: $!";
    }
    waitpid $pid, 0;
    my $exit = $? >> 8;
    open my $fh, '<', $log or die "read log: $!";
    local $/;
    return (scalar <$fh>, $exit);
}

# Fresh throwaway HOME + one install.sh run into it.
sub fresh_install {
    my (%opt) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $home = "$root/home";
    mkdir $home or die "mkdir $home: $!";
    my ($out, $exit) = run_env($root, $home, $opt{on_path}, 'sh', $INSTALL);
    return { root => $root, home => $home, out => $out, exit => $exit };
}

subtest 'install populates libexec and links onto PATH' => sub {
    my $r = fresh_install();
    is $r->{exit}, 0, 'install.sh succeeds';

    my $libexec = "$r->{home}/.local/libexec/aye-buddy";
    ok -d $libexec, 'libexec dir created';
    for my $f (@exec) {
        ok -f "$libexec/$f", "$f installed";
        ok mode_of("$libexec/$f") & oct('111'), "$f is executable";
    }
    for my $f (@data) {
        ok -f "$libexec/$f", "$f installed";
        is mode_of("$libexec/$f") & oct('111'), 0, "$f is not executable";
    }

    my $link = "$r->{home}/.local/bin/aye-buddy";
    ok -l $link, 'aye-buddy symlinked onto PATH';
    is abs_path($link), "$libexec/aye-buddy", 'symlink resolves into libexec';

    # The installed binary actually runs via the symlink: FindBin resolves it
    # into libexec and loads AyeSeccomp.pm from there. --version needs no repo.
    my ($out, $exit) = run_env($r->{root}, $r->{home}, undef, $link, '--version');
    is $exit, 0, 'installed aye-buddy --version exits 0';
    like $out, qr/^aye-buddy [0-9]+\.[0-9]+/, 'prints its version';
};

subtest 'install leaves the host untouched (no rc edits)' => sub {
    my $r = fresh_install();
    like $r->{out}, qr/skipping claude shell function/, 'shell-function step skipped';
    # None of the rc targets install.sh could otherwise touch were created.
    ok !-e "$r->{home}/$_", "no $_ written"
        for qw(.bashrc .zshrc .profile .config/fish/functions/claude.fish);
};

subtest 'install reuses a bin dir already on PATH' => sub {
    my $r = fresh_install(on_path => undef);   # default: bindir not on PATH
    like $r->{out}, qr/not in PATH/, 'warns when the chosen bindir is off PATH';

    my $tmp = tempdir(CLEANUP => 1);
    my $home = "$tmp/home";
    mkdir $home or die $!;
    my ($out) = run_env($tmp, $home, "$home/.local/bin", 'sh', $INSTALL);
    unlike $out, qr/not in PATH/, 'no warning when bindir is already on PATH';
};

subtest 'uninstall removes everything install created' => sub {
    my $r = fresh_install();
    my $libexec = "$r->{home}/.local/libexec/aye-buddy";
    my $link    = "$r->{home}/.local/bin/aye-buddy";
    ok -d $libexec && -l $link, 'installed before uninstall';

    my ($out, $exit) = run_env($r->{root}, $r->{home}, undef,
        'make', '-C', $ROOT, 'uninstall');
    is $exit, 0, 'make uninstall succeeds';
    ok !-e $libexec, 'libexec dir removed';
    ok !-e $link && !-l $link, 'PATH symlink removed';
};

done_testing;
