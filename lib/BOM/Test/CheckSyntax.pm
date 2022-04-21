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
our @EXPORT_OK = qw(check_syntax_on_diff check_syntax_all check_bom_dependency);

=head1 check_syntax_on_diff

Gather common syntax tests which used ammon bom-xxx repos.
It only check updated files compare to master branch.

=cut

sub check_syntax_all {
    my @skipped_files = @_;
    @check_files = `find lib`;

    check_syntax(\@check_files, \@skipped_files);
}

sub check_syntax_on_diff {
    my @skipped_files = @_;
    my @check_files = `git diff --name-only master`;

    check_syntax(\@check_files, \@skipped_files);

}

sub check_syntax {
    my ($check_files, $skipped_files) = @_;
    pass "no file change detected, skip tests" unless @$check_files;

    my %skipped_files = map { $_ => 1 } @$skipped_files;
    my $test = Test::Builder->new;
    foreach my $file (@$check_files) {
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

Check BOM module dependency under currnet lib.
Test fail when new dependency detected.

=cut

sub check_bom_dependency {
    my @dependency_allowed = @_;
    # try to find package name of current repo itself
    my @self_contain_pm = `find lib/BOM/* -maxdepth 0 -type d`;
    @self_contain_pm = map { my $pm = $_; $pm =~ s/lib\/BOM\//BOM::/; $pm =~ s/\s//; $pm } @self_contain_pm;

    # the git grep return like
    # lib/BOM/MyAffiliates.pm:   use BOM::Config;
    # with pathspec lib it filter README and tests
    my $cmd = 'git grep -E "(use|require)\s+BOM::" lib';
    $cmd .= ' bin' if (-d 'bin');
    # also found pod of some pm has comments like
    # lib/BOM/OAuth.pm:  perl -MBOM::Test t/BOM/001_structure.t

    $cmd = join(' | grep -v ', $cmd, @dependency_allowed, @self_contain_pm);
    diag("$cmd");

    my $result = `$cmd`;
    ok !$result, "BOM dependency check";
    if ($result) {
        diag("new BOM module dependency detected!!!");
        diag($result);
    }
}

1;
