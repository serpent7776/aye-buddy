use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

sub rejects {
    my ($opts, $why) = @_;
    my $r = run_aye($opts);
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, $why, 'says why';
    is $r->{argv}, [], 'bwrap never invoked';
}

subtest 'running outside any git/jj repo is rejected' => sub {
    rejects({ no_repo => 1 }, qr/not inside a git or jj repository/);
};

# $HOME is used verbatim as a mount target, so a relative or empty one would
# put the tmpfs home somewhere under the project dir or at the root.
subtest 'a HOME that is not an absolute path is rejected' => sub {
    rejects({ env => { HOME => $_ } }, qr/HOME must be an absolute path/) for '', 'home';
};

# $HOME is a tmpfs the project bind is layered over, so a repo at or above it
# would hand the session the real host home — every other project's transcripts,
# ~/.ssh, ~/.bashrc — with the ~/.claude allowlist bypassed entirely.
subtest 'a repo at $HOME is rejected' => sub {
    rejects({ repo_name => 'home' }, qr/home directory or an ancestor/);
};

subtest 'a repo above $HOME is rejected' => sub {
    rejects({ repo_name => '.' }, qr/home directory or an ancestor/);
};

# Same bypass one level down: ~/.claude is a tmpfs with an allowlist over it, and
# a repo there is below $HOME, so the $HOME guard alone lets it through.
subtest 'a repo at ~/.claude is rejected' => sub {
    rejects({ repo_name => 'home/.claude' }, qr/overlaps .*\/\.claude/);
};

subtest 'a repo under ~/.claude is rejected' => sub {
    rejects({ repo_name => 'home/.claude/dotfiles' }, qr/overlaps .*\/\.claude/);
};

# $project_dir is symlink-resolved, so a ~/.claude the dotfiles repo owns only
# overlaps once the link is followed — and the repo is the ancestor, not the child.
subtest 'a repo ~/.claude symlinks into is rejected' => sub {
    rejects({ repo_name => 'home/dotfiles', claude_link => 'home/dotfiles/claude' },
            qr/overlaps .*\/\.claude/);
};

done_testing;
