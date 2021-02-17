use strict;

use Test::More;
use Test::PerlTidy;

subtest "check modules and test files being tidy" => sub {
    run_tests(
        perltidyrc => '/home/git/regentmarkets/cpan/rc/.perltidyrc',
        exclude    => ['.git'],
        mute       => 1,
    );
};

done_testing;
