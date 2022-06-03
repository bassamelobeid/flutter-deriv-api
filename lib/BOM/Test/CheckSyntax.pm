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
use Test::Builder qw();
use Pod::Coverage;
use Pod::Checker;
use Test::Pod::Coverage;
use Array::Utils qw(intersect);
use BOM::Test::CheckJsonMaybeXS;
use YAML::XS qw(LoadFile);

our @EXPORT_OK = qw(check_syntax_on_diff check_syntax_all check_bom_dependency);
our $skip_tidy;

=head1 check_syntax_on_diff

Gather common syntax tests which used ammon bom-xxx repos.
It only check updated files compare to master branch.

=cut

sub check_syntax_on_diff {
    my @skipped_files = @_;
    my @updated_file  = `git diff --name-only master`;

    if (scalar @updated_file) {
        pass "file change detected";
        diag($_) for @updated_file;

        check_syntax(\@updated_file, \@skipped_files, 'syntax_diff');
        check_tidy(\@updated_file, \@skipped_files);
        check_yaml(@updated_file);

        check_pod_coverage(@updated_file);

    } else {
        pass "no change detected, skip tests";
    }
}

=head1 check_syntax_all

run all the common syntax related check on perl and ymal files.
the test should be same check_syntax_on_diff, but apply to all files.

=cut

sub check_syntax_all {
    my @skipped_files = @_;
    my @updated_file  = `find lib bin -type f`;
    check_syntax(\@updated_file, \@skipped_files);

    @updated_file = `find lib bin t -type f`;
    check_tidy(\@updated_file, \@skipped_files);
    @updated_file = `find . -name "*.yml" -o -name "*.yaml"`;
    check_yaml(@updated_file);
}

=head1 check_syntax

check syntax for perl files

Parameters:

=over

=item * updated_file - array ref of files that need to be check.

=item * skipped_files - array ref of files that will skip syntax check.

=item * syntax_diff - flag to decide if is test for changed files.

=back

=cut

sub check_syntax {
    my ($updated_file, $skipped_files, $syntax_diff) = @_;

    diag("start checking syntax...");
    foreach my $file (@$updated_file) {
        chomp $file;

        next unless (-f $file and $file =~ /[.]p[lm]\z/);
        next if is_skipped_file($file, $skipped_files);

        diag("syntax check on $file:");
        if ($file =~ /^lib\/.+[.]pm\z/) {
            critic_ok($file);
            vars_ok($file);
            BOM::Test::CheckJsonMaybeXS::file_ok($file);
        }

        # syntax_ok test fail on current master, because it never run before.
        # because there are no .pl under /lib, .pl is under /bin.
        # so we only check when the .pl file changed or added.
        # old code as below
        #   for (sort File::Find::Rule->file->name(qr/\.p[lm]$/)->in(Cwd::abs_path . '/lib')) {
        #        syntax_ok($_)      if $_ =~ /\.pl$/;
        #   }
        syntax_ok($file)                                      if $file =~ /[.]pl\z/ and $syntax_diff;
        is(system("$^X", "-c", $file), 0, "file compiles OK") if $file =~ /[.]pl\z/;
    }
}

=head1 check_tidy

Check is_file_tidy for perl files

=cut

sub check_tidy {
    my ($updated_file, $skipped_files) = @_;
    my $test = Test::Builder->new;

    diag("start checking tidy...");
    foreach my $file (@$updated_file) {
        chomp $file;
        next unless -f $file;
        next if $skip_tidy && is_skipped_file($file, $skipped_files);
        # tidy check for all perl files
        if ($file =~ /[.](?:pl|pm|t|cgi)\z/) {
            $test->ok(Test::PerlTidy::is_file_tidy($file, '/home/git/regentmarkets/cpan/rc/.perltidyrc'), "$file: is_file_tidy");
        }
    }
}

=head1 check_yaml

check yaml files format

=cut

sub check_yaml {
    my (@updated_file) = @_;
    diag("start checking yaml...");
    foreach my $file (@updated_file) {
        chomp $file;
        next unless -f $file;
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

sub is_skipped_file {
    my ($check_file, $skipped_files) = @_;
    return unless @$skipped_files;
    return grep { $check_file =~ /$_/ } @$skipped_files;
}

sub check_pod_coverage {
    my @updated_file = @_;
    foreach my $file (@updated_file) {
        chomp $file;
        next unless (-f $file and $file =~ /[.]pm\z/);
        my $podchecker = podchecker($file);
        ok !$podchecker, "check pod syntax for $file";
        # diag($podchecker) if $podchecker;

        my ($module)  = Test::Pod::Coverage::all_modules($file);
        my $pc        = Pod::Coverage->new(package => $module);
        my @naked_sub = $pc->naked;
        use Data::Dumper; $Data::Dumper::Maxdepth=2;
        diag(Dumper(\@naked_sub). 'get_updated_subs'.Dumper(get_updated_subs($file)));
        my @naked_updated_sub=intersect(@naked_sub, get_updated_subs($file));
              ok !@naked_updated_sub, "check pod coverage for updated functoin of $module";
diag($_) for @naked_updated_sub;
    }
}

sub get_updated_subs {
    my ($updated_file) = @_;
    my @changed_lines = `git diff $updated_file`;
    my @updated_subs;
    for (@changed_lines) {
        # get the changed function, sample:
        # @@ -182,4 +187,13 @@ sub is_skipped_file {
        push(@updated_subs, $1) if /@@ sub\s(\w+)\s/;
        # get the new function, sample:
        # +sub get_updated_subs {
        push(@updated_subs, $1) if /\+sub\s(\w+)\s/;
    }
    return @updated_subs;
}

1;
