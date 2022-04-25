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

sub check_syntax_on_diff {
    my @skipped_files = @_;
    my @check_files   = `git diff --name-only master`;

    if (scalar @check_files) {
        pass "file change detected";
        diag($_) for @check_files;

        check_syntax(\@check_files, \@skipped_files, 1);
        check_tidy(@check_files);
        check_yaml(@check_files);
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
    my @check_files   = `find lib bin -type f`;
    check_syntax(\@check_files, \@skipped_files);

    @check_files = `find lib bin t -type f`;
    check_tidy(@check_files);

    @check_files = `find . -name "*.yml" -o -name "*.yaml"`;
    check_yaml(@check_files);
}

=head1 check_syntax

check syntax for perl files

=cut

sub check_syntax {
    my ($check_files, $skipped_files, $check_diff) = @_;

    my %skipped_files;
    my @skipped_path;
    foreach (@$skipped_files) {
        if (-f $_) {
            # if it is file ,then exact match
            $skipped_files{$_} = 1;
        } else {
            # otherwise do match
            push(@skipped_path, $_);
        }
    }

    diag("start checking syntax...");
    foreach my $file (@$check_files) {
        chomp $file;

        next unless (-f $file and $file =~ /[.]p[lm]\z/);
        next if exists $skipped_files{$file};

        my $skip_match;
        foreach (@skipped_path) {
            if ($file =~ /$_/) {
                $skip_match = 1;
                last;
            }
        }
        next if $skip_match;

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
        syntax_ok($file) if $file =~ /[.]pl\z/ and $check_diff;

    }
}

=head1 check_tidy

Check is_file_tidy for perl files

=cut

sub check_tidy {
    my (@check_files) = @_;
    my $test = Test::Builder->new;

    diag("start checking tidy...");
    foreach my $file (@check_files) {
        chomp $file;
        next unless -f $file;
        # tidy check for all perl files
        if ($file =~ /[.](?:pl|pm|t)\z/) {
            $test->ok(Test::PerlTidy::is_file_tidy($file, '/home/git/regentmarkets/cpan/rc/.perltidyrc'), "$file: is_file_tidy");
        }
    }
}

=head1 check_yaml

check yaml files format

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
