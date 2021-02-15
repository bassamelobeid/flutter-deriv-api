use strict;

use Test::More;
use Test::Syntax::Aggregate;
use File::Find::Rule;
use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use Test::Strict;
use Cwd;
use Test::PerlTidy;

my $pattern = $ARGV[0];    # confines test to just files matching this pattern.

subtest "Check modules in lib" => sub {
    for (sort File::Find::Rule->file->name(qr/\.p[lm]$/)->in(Cwd::abs_path . '/lib')) {
        /$pattern/ || next if $pattern;
        next               if m!/WebsocketAPI/Tests/|/WebsocketAPI/Helpers/!;
        syntax_ok($_)      if $_ =~ /\.pl$/;
        critic_ok($_);
    }
};

subtest "check modules and test files being tidy" => sub {
    run_tests(
        perltidyrc => '/home/git/regentmarkets/cpan/rc/.perltidyrc',
        exclude    => ['.git', qr{/WebsocketAPI/Helpers/}, qr{/WebsocketAPI/Tests/}],
        mute       => 1,
    );
};

done_testing;
