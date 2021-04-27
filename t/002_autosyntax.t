use strict;

use Test::More;
use Test::Syntax::Aggregate;
use File::Find::Rule;
use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use Test::Strict;
use Cwd;
use Test::PerlTidy;

my $base_dir = Cwd::abs_path;
my $lib_dir  = "$base_dir/lib";

my $lib_pattern = $ENV{SYNTAX_CHUNK_NAME} || '/lib';
for ($lib_pattern) {
    s(^lib$)(/lib);    # lib means /lib
    s(^cgi$)();        # don't do any lib
}

if ($lib_pattern) {
    my @lib_targets = grep { read_head($_) =~ /^## no autosyntax/m ? (note "Skipping $_" and 0) : 1 }
        grep { m($lib_pattern)i }
        sort File::Find::Rule->file->name(qr/\.p[lm]$/)->in($lib_dir);

    if (@lib_targets) {
        subtest "Check modules in lib" => sub {
            pass 'Syntax check starts here';
            for (@lib_targets) {
                syntax_ok($_) if $_ =~ /\.pl$/;
            }
        }
    }
}

sub read_head {
    my $fname = shift;
    open my $fd, "<", $fname or die "Can't open $fname: $!";
    read $fd, my $buf, 8192;
    return $buf;
}

subtest "check modules and test files being tidy" => sub {
    run_tests(
        perltidyrc => '/home/git/regentmarkets/cpan/rc/.perltidyrc',
        exclude    => ['.git'],
        mute       => 1,
    );
};

done_testing;
