package BOM::Test::CheckSyntax;

use strict;
use warnings;

use Exporter 'import';
use Test::More;
use Test::Exception;
use Test::Vars;
use Test::Strict;
use Test::PerlTidy;
use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use BOM::Test::CheckJsonMaybeXS;
use Test::Builder qw();
use YAML::XS qw(LoadFile);
our @EXPORT_OK = qw(check_syntax_on_diff check_bom_dependency);

=head1 check_syntax_on_diff

Gather common syntax tests which used ammon bom-xxx repos.
and the tests only apply to updated files compare to master branch.

=cut

sub check_syntax_on_diff {
    my @skipped_files = @_;
    my %skipped_files = map { $_ => 1 } @skipped_files;
    if (@skipped_files) {
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

=head1 check_bom_dependency

check BOM modules dependency under currnet lib
skip test files, Makefile, .proverc, README.md...
also found pod of some pm has comments like
lib/BOM/OAuth.pm:  perl -MBOM::Test t/BOM/001_structure.t

=cut

sub check_bom_dependency {
    my @dependency_allowed = @_;
    # try to find package name of current repo itself
    my @self_contain_pm = `find lib/BOM/* -maxdepth 0 -type d`;
    @self_contain_pm = map { my $pm = $_; $pm =~ s/lib\/BOM\//BOM::/; $pm =~ s/\s//; $pm } @self_contain_pm;

    # the git grep return like
    # lib/BOM/MyAffiliates.pm:   use BOM::Config;
    # with pathspec lib it filter all README and tests
    my $cmd = 'git grep -E "(use|require)\s+BOM::" lib/';
    $cmd = join(' | grep -v ', $cmd, @dependency_allowed, @self_contain_pm);
    note("$cmd");

    my $result = `$cmd`;
    ok !$result, "BOM dependency check";
    diag($result) if $result;
}

1;
