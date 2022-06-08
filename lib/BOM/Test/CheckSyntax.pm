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
use Pod::Checker qw(podchecker);
use Test::Pod::Coverage;
use Array::Utils qw(intersect);
use BOM::Test::CheckJsonMaybeXS;
use YAML::XS qw(LoadFile);
use Data::Dumper;
$Data::Dumper::Maxdepth = 1;

our @EXPORT_OK = qw(check_syntax_on_diff check_syntax_all check_bom_dependency);
our $skip_tidy;

=head1 NAME

BOM::Test::CheckSyntax

=head1 DESCRIPTION

Gather the common syntax tests for bom related repos.


=head2 check_syntax_on_diff

Check the syntax for updated files compare to master branch.

=cut

sub check_syntax_on_diff {
    my @skipped_files = @_;
    # update master before compare diff
    my $result = `git fetch --no-tags origin master`;
    diag($result) if $result;

    my @check_files = `git diff --name-only origin/master`;

    if (scalar @check_files) {
        pass "file change detected";
        diag($_) for @check_files;

        check_syntax(\@check_files, \@skipped_files, 'syntax_diff');
        check_tidy(\@check_files, \@skipped_files);
        check_yaml(@check_files);
        check_pod_coverage(@check_files);
    } else {
        pass "no change detected, skip tests";
    }
}

=head2 check_syntax_all

Run the syntax check same as check_syntax_on_diff, but apply to all files.

=cut

sub check_syntax_all {
    my @skipped_files = @_;
    my @check_files   = `find lib bin -type f`;
    check_syntax(\@check_files, \@skipped_files);

    @check_files = `find lib bin t -type f`;
    check_tidy(\@check_files, \@skipped_files);
    @check_files = `find . -name "*.yml" -o -name "*.yaml"`;
    check_yaml(@check_files);
}

=head2 check_syntax

check syntax for perl files

Parameters:

=over

=item * check_files - array ref of files that need to be check.

=item * skipped_files - array ref of files that will skip syntax check.

=item * syntax_diff - flag to decide if is test for changed files.

=back

=cut

sub check_syntax {
    my ($check_files, $skipped_files, $syntax_diff) = @_;

    diag("start checking syntax...");
    foreach my $file (@$check_files) {
        chomp $file;

        next unless (-f $file and $file =~ /[.]p[lm]\z/);
        next if _is_skipped_file($file, $skipped_files);

        diag("syntax check on $file:");
        if ($file =~ /^lib\/.+[.]pm\z/) {
            critic_ok($file);
            vars_ok($file);
            BOM::Test::CheckJsonMaybeXS::file_ok($file);
        }

        is(system("$^X", "-c", $file), 0, "file compiles OK") if $file =~ /[.]pl\z/;
        # syntax_ok test fail on lots of files, because it never run before.
        # so we only check when the .pl file changed or added.
        syntax_ok($file) if $file =~ /[.]pl\z/ and $syntax_diff;
    }
}

=head2 check_tidy

Check is_file_tidy for perl files

=cut

sub check_tidy {
    my ($check_files, $skipped_files) = @_;
    my $test = Test::Builder->new;

    diag("start checking tidy...");
    $Test::PerlTidy::MUTE = 1;
    foreach my $file (@$check_files) {
        chomp $file;
        next unless -f $file;
        next if $skip_tidy && _is_skipped_file($file, $skipped_files);
        # tidy check for all perl files
        if ($file =~ /[.](?:pl|pm|t|cgi)\z/) {
            $test->ok(Test::PerlTidy::is_file_tidy($file, '/home/git/regentmarkets/cpan/rc/.perltidyrc'), "$file: is_file_tidy");
        }
    }
}

=head2 check_yaml

check yaml files syntax

=cut

sub check_yaml {

    my (@check_files) = @_;
    diag("start checking yaml...");
    foreach my $file (@check_files) {
        chomp $file;
        next unless -f $file;
        if ($file =~ /\.(yml|yaml)$/ and not $file =~ /invalid\.yml$/) {
            lives_ok { LoadFile($file) } "$file YAML valid";
        }
    }
}

=head2 check_bom_dependency

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

sub _is_skipped_file {
    my ($check_file, $skipped_files) = @_;
    return unless @$skipped_files;
    return grep { $check_file =~ /$_/ } @$skipped_files;
}

=head2 check_pod_coverage

check the pod coverage for the updated perl modules.

=cut

sub check_pod_coverage {
    my @check_files = @_;
    diag("start checking pod for perl modules...");

    foreach my $file (@check_files) {
        chomp $file;
        next unless (-f $file and $file =~ /[.]pm\z/);
        my $podchecker = podchecker($file);
        ok !$podchecker, "check pod syntax for $file";
        diag("Please help adding the NAME and DESCRIPTION sections in the pod if missing, and fix the pod syntax issue if there are warnings.")
            if $podchecker;
        my ($module) = Test::Pod::Coverage::all_modules($file);
        my $pc = Pod::Coverage->new(package => $module);
        warn $pc->why_unrated if $pc->why_unrated;
        my @naked_sub = $pc->naked;

        my @updated_subs      = get_updated_subs($file);
        my @naked_updated_sub = intersect(@naked_sub, @updated_subs);
        ok !@naked_updated_sub, "check pod coverage for $module";

        diag("$module naked_sub: " . Dumper(\@naked_sub) . 'updated_subs: ' . Dumper(\@updated_subs));
        if (scalar @naked_updated_sub) {
            diag("The private subroutine start with '_' will be ignored.");
            diag('Please add pod document for the following subroutines:');
            diag(explain @naked_updated_sub);
        }
    }
}

=head2 get_updated_subs

Get updated or new subroutines for the giving perl file.
Based on results of git diff master

=cut

sub get_updated_subs {
    my ($check_file) = @_;
    my @changed_lines = `git diff origin/master $check_file`;
    my %updated_subs;
    my $pm_subs = get_pm_subs($check_file);
    for (@changed_lines) {
        # filter the comments [^#] or deleted line [^-]
        # get the changed function, sample:
        # @@ -182,4 +187,13 @@ sub is_skipped_file {
        if (/^[^-#]*?@@.+\s[+](\d+).+@@ .*?sub\s(\w+)\s/) {
            if ($pm_subs->{$2}) {
                diag("$2 change start $1 " . Dumper($pm_subs->{$2}));
                # $1 is the number of change start, but with 2 lines extra context
                # if the changed lines is greater than end, it means the sub is not really changed
                next if ($1 + 2 >= $pm_subs->{$2}{end});
            }
            $updated_subs{$2} = 1;
        } elsif (/^\+[^#]*?sub\s(\w+)\s/) {
            # get the new function, sample:
            # +sub async newsub {
            $updated_subs{$1} = 1;
        } elsif (/^[^-#]*?sub\s(\w+)\s/) {
            # if the updated lines near the sub name, it shows as original
            $updated_subs{$1} = 1;
        }

    }
    return keys %updated_subs;
}

=head2 get_pm_subs

Try to get all the subs of a perl file, and the start end line number of each sub.
Currently it can NOT handle sub which defined with custom keywrod like "async sub foo {"

=cut

sub get_pm_subs {
    my ($check_file) = @_;
    my %results;
    use PPI;
    my $doc  = PPI::Document->new($check_file);
    my $subs = $doc->find('PPI::Statement::Sub');

    foreach my $sub (@$subs) {
        my @t = $sub->tokens;
        $results{$sub->name}{start} = $t[0]->location->[0];
        $results{$sub->name}{end}   = $t[-1]->location->[0];
    }
    # diag("get_pm_subs: $check_file" . Dumper(\%results));
    return %results ? \%results : undef;
}

1;
