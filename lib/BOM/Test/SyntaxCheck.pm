package BOM::Test::SyntaxCheck;

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Vars;
use Test::Strict;
use Test::PerlTidy;
use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use BOM::Test::CheckJsonMaybeXS;
use Test::Builder qw();
use YAML::XS qw(LoadFile);

sub syntax_check_on_diff {

    my %skipped_files = map { $_ => 1 } @_;
    if (%skipped_files) {
        diag("skipped_files:");
        diag($_) for keys %skipped_files;
    }

    my @changed_files = `git diff --name-only master`;

    if (@changed_files) {
        pass "file change detected";
        diag($_) for @changed_files;
    } else {
        pass "no file change detected, skip tests";
    }

    my $test = Test::Builder->new;
    foreach my $file (@changed_files) {
        chomp $file;
        next unless -f $file;

        # those check only apply on perl files under lib
        if ($file =~ /^lib\/.+[.]p[lm]\z/ and not $skipped_files{$file}) {
            note("syntax check on $file:");
            syntax_ok($file);
            vars_ok($file);
            critic_ok($file);
            BOM::Test::CheckJsonMaybeXS::file_ok($file);
        }

        # tidy check for all perl files
        if ($file =~ /[.](?:pl|pm|t)\z/) {
            $test->ok(Test::PerlTidy::is_file_tidy($file, '/home/git/regentmarkets/cpan/rc/.perltidyrc'), "$file: is_file_tidy");
        }

        if ($file =~ /\.(yml|yaml)$/ and not $file =~ /invalid\.yml$/) {
            lives_ok { LoadFile($file) } "$file YAML valid";
        }

    }
}
