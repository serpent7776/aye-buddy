use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use AyeTest;

subtest 'running outside any git/jj repo is rejected' => sub {
    my $r = run_aye({ no_repo => 1 });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/not inside a git or jj repository/, 'says why';
    is $r->{argv}, [], 'bwrap never invoked';
};

# $HOME is a tmpfs the project bind is layered over, so a repo at or above it
# would hand the session the real host home — every other project's transcripts,
# ~/.ssh, ~/.bashrc — with the ~/.claude allowlist bypassed entirely.
subtest 'a repo at $HOME is rejected' => sub {
    my $r = run_aye({ repo_name => 'home' });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/home directory or an ancestor/, 'says why';
    is $r->{argv}, [], 'bwrap never invoked';
};

subtest 'a repo above $HOME is rejected' => sub {
    my $r = run_aye({ repo_name => '.' });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/home directory or an ancestor/, 'says why';
    is $r->{argv}, [], 'bwrap never invoked';
};

# Same bypass one level down: ~/.claude is a tmpfs with an allowlist over it, and
# a repo there is below $HOME, so the $HOME guard alone lets it through.
subtest 'a repo at or under ~/.claude is rejected' => sub {
    for my $repo ('home/.claude', 'home/.claude/dotfiles') {
        my $r = run_aye({ repo_name => $repo });
        is $r->{exit}, 1, "$repo exits 1";
        like $r->{err}, qr/overlaps ~\/\.claude/, 'says why';
        is $r->{argv}, [], 'bwrap never invoked';
    }
};

# $project_dir is symlink-resolved, so a ~/.claude the dotfiles repo owns only
# overlaps once the link is followed — and the repo is the ancestor, not the child.
subtest 'a repo ~/.claude symlinks into is rejected' => sub {
    my $r = run_aye({ repo_name => 'home/dotfiles',
                      claude_link => 'home/dotfiles/claude' });
    is $r->{exit}, 1, 'exits 1';
    like $r->{err}, qr/overlaps ~\/\.claude/, 'says why';
    is $r->{argv}, [], 'bwrap never invoked';
};

done_testing;
