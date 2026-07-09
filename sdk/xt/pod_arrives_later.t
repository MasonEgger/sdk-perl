# ABOUTME: Author test (spec R65, finding A11): no POD or comment in lib/ may
# ABOUTME: still defer shipped v0.1/v0.2 surface to a "later phase/plan step".
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Find ();
use FindBin ();

my $lib = "$FindBin::Bin/../lib";

# The stale-deferral tells swept at the v0.2 close (finding A11). Everything
# in lib/ ships; text claiming a feature "arrives later", lands "in a later
# phase / plan step", or is "deferred past v0.1" describes a state that no
# longer exists. Legitimate runtime uses of "later" ("the later
# ResolveActivity", "completed later through a handle") do not match these.
my @stale = (
    qr/later\s+plan\s+steps?/i,
    qr/later\s+phases?\b/i,
    qr/arrives?\s+later\b/i,
    qr/deferred\s+past\s+v0/i,
);

my @files;
File::Find::find(
    { wanted => sub { push @files, $File::Find::name if /\.pm\z/ },
      no_chdir => 1 },
    $lib);
T2->ok(scalar @files, 'found .pm files under lib');

my @hits;
for my $file (sort @files) {
    open my $fh, '<:encoding(UTF-8)', $file or die "open $file: $!";
    while (my $line = readline $fh) {
        for my $pattern (@stale) {
            next unless $line =~ $pattern;
            chomp $line;
            (my $rel = $file) =~ s/\Q$lib\E\///;
            push @hits, "$rel:$.: $line";
            last;
        }
    }
    close $fh;
}

T2->is(\@hits, [], 'no stale arrives-later deferral text remains in lib')
    or T2->diag(join "\n", @hits);

T2->done_testing;
