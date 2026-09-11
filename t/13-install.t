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

# Fresh throwaway HOME + one install.sh run into it. Extra args go to install.sh.
sub fresh_install {
    my (%opt) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $home = "$root/home";
    mkdir $home or die "mkdir $home: $!";
    my ($out, $exit) = run_env($root, $home, $opt{on_path},
        'sh', $opt{install} // $INSTALL, @{ $opt{args} // [] });
    return { root => $root, home => $home, out => $out, exit => $exit };
}

# The version line the installed aye-buddy prints, e.g. "aye-buddy 0.1.0 (abc1234)".
sub installed_version {
    my ($r) = @_;
    my ($out) = run_env($r->{root}, $r->{home}, undef,
        "$r->{home}/.local/bin/aye-buddy", '--version');
    chomp $out;
    return $out;
}

# A copy of the installable files in a fresh dir, with aye-buddy passed
# through $edit (a sub over its text) — stands in for a source tree that is
# not a git checkout, such as an unpacked release tarball.
sub source_tree {
    my ($edit) = @_;
    my $dir = tempdir(CLEANUP => 1);
    for my $f (@exec, @data, 'install.sh') {
        open my $in, '<', "$ROOT/$f" or die "read $f: $!";
        my $text = do { local $/; <$in> };
        $text = $edit->($text) if $f eq 'aye-buddy';
        open my $o, '>', "$dir/$f" or die "write $f: $!";
        print $o $text;
        close $o or die $!;
    }
    return $dir;
}

# The rc targets install.sh may write the shell function into; which one it
# picks depends on the invoking user's login shell.
my @rc = qw(.bashrc .zshrc .profile .config/fish/functions/claude.fish);

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

# The source keeps a $Format:%h$ placeholder for git archive to expand; from a
# checkout install.sh fills it itself when git is at hand.
subtest 'install from a checkout bakes in the commit hash' => sub {
    my $hash = `git -C "$ROOT" rev-parse --short HEAD 2>/dev/null`;
    chomp $hash;
    skip_all 'not a git checkout, or no git' unless $? == 0 && $hash =~ /^[0-9a-f]+$/;
    # This checkout could itself be an unpacked archive, already expanded.
    open my $fh, '<', "$ROOT/aye-buddy" or die $!;
    my $src = do { local $/; <$fh> };
    skip_all 'placeholder already expanded in this tree' unless $src =~ /Format:%h/;
    my $r = fresh_install();
    is $r->{exit}, 0, 'install.sh succeeds';
    like installed_version($r), qr/^aye-buddy [0-9.]+ \(\Q$hash\E\)$/, 'version carries HEAD';
};

subtest 'install without git prints the bare version' => sub {
    # A git that always fails stands in for one that is missing.
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/git" or die $!;
    print $fh "#!/bin/sh\nexit 1\n";
    close $fh;
    chmod 0755, "$dir/git" or die $!;
    my $r = fresh_install(on_path => $dir);
    is $r->{exit}, 0, 'install.sh still succeeds';
    like installed_version($r), qr/^aye-buddy [0-9.]+$/, 'no hash, no noise';
};

subtest 'an already expanded placeholder is installed as is' => sub {
    my $src = source_tree(sub { my $t = shift; $t =~ s/\$Format:%h\$/deadbee/ or die 'no placeholder'; $t });
    my $r = fresh_install(install => "$src/install.sh");
    is $r->{exit}, 0, 'install.sh succeeds';
    like installed_version($r), qr/^aye-buddy [0-9.]+ \(deadbee\)$/, 'the archive hash survives';
};

subtest 'install leaves the host untouched (no rc edits)' => sub {
    my $r = fresh_install();
    like $r->{out}, qr/skipping claude shell function/, 'shell-function step skipped';
    # None of the rc targets install.sh could otherwise touch were created.
    ok !-e "$r->{home}/$_", "no $_ written" for @rc;
};

subtest '-y installs the shell function without a tty' => sub {
    my $r = fresh_install(args => ['-y']);
    is $r->{exit}, 0, 'install.sh -y succeeds';
    unlike $r->{out}, qr/skipping/, 'nothing skipped';
    my @written = grep { -f "$r->{home}/$_" } @rc;
    is scalar @written, 1, 'exactly one rc target written' or diag "@written";
    open my $fh, '<', "$r->{home}/$written[0]" or die $!;
    my $rc = do { local $/; <$fh> };
    like $rc, qr/aye-buddy --agent claude/, 'rc forwards claude to aye-buddy';
};

subtest '-n skips the shell function without asking' => sub {
    my $r = fresh_install(args => ['-n']);
    is $r->{exit}, 0, 'install.sh -n succeeds';
    like $r->{out}, qr/skipping shell function install/, 'shell-function step skipped';
    unlike $r->{out}, qr/not a tty/, 'never reached the tty check';
    ok !-e "$r->{home}/$_", "no $_ written" for @rc;
};

subtest 'bad or conflicting flags are a usage error' => sub {
    for my $args (['-x'], ['-y', '-n'], ['-n', '-y']) {
        my $r = fresh_install(args => $args);
        is $r->{exit}, 2, "install.sh @$args exits 2";
        ok !-e "$r->{home}/.local", "install.sh @$args installs nothing";
    }
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
