use strict;
use warnings;

BEGIN {
    require "./lib/BOM/Backoffice/PlackApp.pm";
    BOM::Backoffice::PlackApp::Streaming->import();
}

use Test::More;
use File::Find::Rule;
use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use Test::Strict;
use Cwd;
use Test::PerlTidy;

my $pattern = $ARGV[0];        # confines test to just files matching this pattern.
my $PATH    = Cwd::abs_path;
my @tested_modules;

subtest "Preload all CGIs" => sub {
    my $app = BOM::Backoffice::PlackApp::Streaming->new(
        preload => [qw/*.cgi/],
        root    => '/home/git/regentmarkets/bom-backoffice'
    )->to_app;

    @tested_modules = keys %INC;

    ok $app, "App can be initialized with all CGIs";
};

subtest 'Check modules which are not covered by above test' => sub {
    my @scripts = get_scripts(qr/\.pm$/);

    my @remaining_modules = grep { !is_module_tested($_) } @scripts;

    syntax_ok($_) for @remaining_modules;
};

subtest 'Check syntax for pl files' => sub {
    syntax_ok($_) for get_scripts(qr/\.pl$/);
};

subtest 'Run perl critic on all modules' => sub {
    all_critic_ok(get_scripts(qr/\.p[lm]|\.cgi$/));
};

sub get_scripts {
    my @scripts = File::Find::Rule->file->name(shift)->in($PATH);

    return sort grep { $pattern ? /$pattern/ : 1 } @scripts;
}

sub is_module_tested {
    my $m = shift;
    grep { $m =~ /$_/ } @tested_modules;
}

subtest "check modules and test files being tidy" => sub {
    run_tests(
        perltidyrc => '/home/git/regentmarkets/cpan/rc/.perltidyrc',
        exclude    => ['.git'],
        mute       => 1,
    );
};

done_testing;
