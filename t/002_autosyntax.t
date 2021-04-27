use strict;
use warnings;

use Test::More;
use Test::Syntax::Aggregate;
use File::Find::Rule;
use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use Test::Strict;
use Cwd;
use Test::PerlTidy;

subtest "Check modules in lib" => sub {
    pass 'Syntax check starts here';
    for (sort File::Find::Rule->file->name(qr/\.p[lm]$/)->in(Cwd::abs_path . '/lib')) {
        syntax_ok($_) if $_ =~ /\.pl$/;
    }
};

subtest "check modules and test files being tidy" => sub {
    run_tests(
        perltidyrc => '/home/git/regentmarkets/cpan/rc/.perltidyrc',
        exclude    => ['.git', 'srp'],
        mute       => 1,
    );
};

done_testing;
