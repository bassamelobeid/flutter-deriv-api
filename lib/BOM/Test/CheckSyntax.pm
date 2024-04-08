package BOM::Test::CheckSyntax;

use strict;
use warnings;

=head1 NAME

BOM::Test::CheckSyntax

=head1 DESCRIPTION

Run the common syntax tests for bom repos.

=cut

use Exporter 'import';
use Test::More;
use Test::Exception;
use Test::Vars;
use Test::Strict;
use Test::PerlTidy;
use Perl::Tidy::Sweetened;
use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use Test::Builder qw();
use Pod::Coverage;
use Pod::Checker qw(podchecker);
use Test::Pod::Coverage;
use Array::Utils qw(intersect);
use BOM::Test::CheckJsonMaybeXS;
use BOM::Test::LocalizeSyntax qw(check_localize_string_structure);
use YAML::XS                  qw(LoadFile);
use Data::Dumper;

# This module is imported in .proverc already. Here we import it again to disable end_test
# because `end test` will make test fail with the error of plan number
use Test::Warnings ':no_end_test';

our @EXPORT_OK = qw(check_syntax_on_diff check_syntax_all check_bom_dependency);
our $skip_tidy;

our %bom_repo_to_module = (
    'regentmarkets/bom-user'           => ['BOM::User', 'BOM::TradingPlatform', 'BOM::MT5'],
    'regentmarkets/bom-config'         => 'BOM::Config',
    'regentmarkets/bom-rules'          => 'BOM::Rules',
    'regentmarkets/bom-market'         => 'BOM::Market',
    'regentmarkets/bom-platform'       => 'BOM::Platform',
    'regentmarkets/bom'                => ['BOM::Contract', 'BOM::Product'],
    'regentmarkets/bom-cryptocurrency' => 'BOM::CTC',
    'regentmarkets/bom-myaffiliates'   => 'BOM::MyAffiliates',
    'regentmarkets/bom-transaction'    => 'BOM::Transaction',
    'regentmarkets/bom-rpc'            => 'BOM::RPC',
    'regentmarkets/bom-pricing'        => 'BOM::Pricing',
    'regentmarkets/bom-postgres'       => 'BOM::Database',
    'regentmarkets/bom-test'           => 'BOM::Test',
    'regentmarkets/bom-populator'      => 'BOM::Populator',
    'regentmarkets/bom-oauth'          => 'BOM::OAuth'
);

=head2 check_syntax_on_diff

Run serial syntax tests for updated files compare to master branch.

=over 4

=item * skipped_files - file list that skip the syntax check.

=back

=cut

sub check_syntax_on_diff {
    my @skipped_files = @_;
    # update master before compare diff
    my $result = _run_command("git fetch --no-tags origin master");
    diag($result) if $result;

    my @check_files = _run_command("git diff --diff-filter=ACMRT --name-only origin/master | grep -v -E '^docs' ");

    if (scalar @check_files) {
        pass "file change detected";
        diag($_) for @check_files;

        check_syntax(\@check_files, \@skipped_files, 'syntax_diff');
        check_tidy(\@check_files, \@skipped_files);
        check_yaml(@check_files);
        check_localize_string_structure(@check_files);
        check_log_any_adapter(@check_files);
    } else {
        pass "no change detected, skip tests";
    }
}

=head2 check_syntax_all

Run the syntax tests same as check_syntax_on_diff, but apply to all files.

=over 4

=item * skipped_files - file list that skip the syntax check.

=back

=cut

sub check_syntax_all {
    my @skipped_files = @_;
    my @check_files   = _run_command("find lib bin -type f");
    check_syntax(\@check_files, \@skipped_files);

    @check_files = _run_command("find lib bin t -type f");
    check_tidy(\@check_files, \@skipped_files);
    @check_files = _run_command('find . \( -path "./.git" -o -path "./docs" \) -prune -o -type f \( -name "*.yml" -o -name "*.yaml" \) -print');
    check_yaml(@check_files);
    @check_files = _run_command("find lib -type f");
    check_log_any_adapter(@check_files);
}

=head2 check_syntax

Run serial syntax tests for perl files, which included:
Test::Perl::Critic
Test::Vars
Test::Strict
BOM::Test::CheckJsonMaybeXS;

Parameters:

=over

=item * check_files - array ref of files that need to be check.

=item * skipped_files - array ref of files that will skip syntax check.

=item * syntax_diff - flag to indicate test for changed files.

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
            critic_ok($file, 'test perlcritic');
            # TODO Test::Vars will complain Object::Pad fields in perl 5.38.2
            # For example, https://github.com/regentmarkets/bom-test/blob/master/lib/BOM/Test/CustomerIO/Webserver.pm#L65
            # there is a patch but not released yet. waiting for new version
            # if there is still no new version when we upgrade perl again, we will disable it and use
            # Perl::Critic::Policy::Variables::ProhibitUnusedVariables
            # See https://github.com/houseabsolute/p5-Test-Vars/issues/47
            vars_ok($file, ignore_vars => ['@(Object::Pad/slots)', '@(Object::Pad/fields)']);
            BOM::Test::CheckJsonMaybeXS::file_ok($file);
        }

        is(system("$^X", "-c", $file), 0, "file compiles OK") if $file =~ /[.]pl\z/;
        # syntax_ok test fail on lots of files, because it never run before.
        # so we only check when the .pl file changed or added.
        syntax_ok($file) if $file =~ /[.]pl\z/ and $syntax_diff;
    }
}

=head2 check_tidy

Check Test::PerlTidy for perl files

=over

=item * check_files - array ref of files that need to be check.

=item * skipped_files - array ref of files that will skip tidy check.

=back

=cut

sub check_tidy {
    my ($check_files, $skipped_files) = @_;
    my $test = Test::Builder->new;
    ## no critic (ProhibitNoWarnings)
    no warnings 'redefine';
    my $origin_perltidy = \&Perl::Tidy::perltidy;

    *Perl::Tidy::perltidy = sub {
        my @caller = caller(1);
        if ($caller[3] eq 'Test::PerlTidy::is_file_tidy') {
            return Perl::Tidy::Sweetened::perltidy(@_);
        } else {
            return $origin_perltidy->(@_);
        }
    };
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
    *Perl::Tidy::perltidy = $origin_perltidy;
}

=head2 check_yaml

check yaml files can load YAML::XS successfully.

=over

=item * check_files - array of files that need to be check.

=back

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

=head2 check_log_any_adapter

Check whether there is any Log::Any::Adapter in module.
Test fail if module used Log::Any::Adapter.
Except modules like BOM::Feed::Script::* which will be used directly by the very simple scripts without any other logic flow.

=cut

sub check_log_any_adapter {

    my @check_files  = @_;
    my @exclude_dir  = ("lib\/BOM\/Feed\/Script\/");
    my $filter_files = join("|", @exclude_dir);
    my @pm_files     = grep { /[.]pm\z/ } @check_files;
    @pm_files = grep { /[.]pm\z/ && !/$filter_files/ } @check_files if $filter_files;

    my @result = map { _run_command('git grep -E "(use|require)\s+Log::Any::Adapter(\s+|;)" ' . $_) } @pm_files;

    ok !@result, "Check whether Log::Any::Adapter is not used in modules";
    if (@result) {
        diag(qq{Log::Any::Adapter is used in the following modules!!});
        diag(join("\n", @result));
    }

}

=head2 check_bom_dependency

Check BOM module usage under lib and bin under the root of a repo.
Test fail when new dependency detected, which means the BOM module is not in the list of runtime_required_repos.yml.

=over

=item * dependency_allowed - array of BOM modules that already used in lib.

=back

=cut

sub check_bom_dependency {
    my @dependency_allowed = @_;
    my @self_contain_pm    = _get_self_name_space();
    my $cmd                = 'git grep -E "(use|require)\s+BOM::" lib';
    $cmd .= ' bin' if (-d 'bin');
    # also found pod of some pm has comments like
    # lib/BOM/OAuth.pm:  perl -MBOM::Test t/BOM/001_structure.t
    my $required_repos_yml = 'runtime_required_repos.yml';
    if (-e $required_repos_yml) {
        my $required_repos = YAML::XS::LoadFile($required_repos_yml);
        unless (ref($required_repos) eq 'ARRAY') {
            warn "$required_repos_yml format has issue.";
        } else {
            foreach (@$required_repos) {
                my $module = $bom_repo_to_module{$_};
                if (ref($module) eq 'ARRAY') {
                    push @dependency_allowed, @$module;
                } elsif ($module) {
                    push @dependency_allowed, $module;
                }
            }

        }
    }
    $cmd = join(' | grep -v ', $cmd, @dependency_allowed, @self_contain_pm);

    my @result = _run_command($cmd);
    ok !@result, "BOM dependency check";
    if (@result) {
        diag(
            qq{New BOM module dependency detected!!!
Please refer to the current dependency list at https://wikijs.deriv.cloud/en/Backend/Quality/bom-module-dependency-list.
Before adding any new dependencies, please verify if it is necessary to include them in the current list. 
If the new dependencies are required, please add the following modules into runtime_required_repos.yml and test_required_repos.yml. Also, update the wikijs documentation.
(You may need to create runtime_required_repos.yml if it doesn't exist)}
        );
        diag(join("\n", @result));
    }
}

=head2 check_pod_coverage

check the pod coverage for the updated perl modules.

=over

=item * check_files - file list that need to be check.

=back

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

        diag("$module naked_sub: @naked_sub updated_subs: @updated_subs");
        if (scalar @naked_updated_sub) {
            diag("The private subroutine start with '_' will be ignored.");
            diag('Please add pod document for the following subroutines:');
            diag(explain(\@naked_updated_sub));
        }
    }
}

=head2 _get_updated_subs

Get updated or new subroutines for the giving perl file.
Based on results of git diff master

=over

=item * check_file - perl file that need to be check.

=back

Returns list of updated sub names

=cut

sub _get_updated_subs {
    my ($check_file) = @_;
    my @changed_lines = _run_command("git diff origin/master $check_file");
    my %updated_subs;
    my $pm_subs = _get_pm_subs($check_file);
    for (@changed_lines) {
        # filter the comments [^#] or deleted line [^-]
        # get the changed function, sample:
        # @@ -182,4 +187,13 @@ sub is_skipped_file {
        if (/^[^-#]*?@@.+\s[+](\d+).+@@ .*?sub\s(\w+)\s/) {
            if ($pm_subs && $pm_subs->{$2}) {
                local $Data::Dumper::Maxdepth = 1;
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

sub _get_pm_subs {
    my ($check_file) = @_;
    my %results;
    use PPI;
    my $doc  = PPI::Document->new($check_file);
    my $subs = $doc->find('PPI::Statement::Sub');
    return undef unless $subs;
    foreach my $sub (@$subs) {
        my @t = $sub->tokens;
        $results{$sub->name}{start} = $t[0]->location->[0];
        $results{$sub->name}{end}   = $t[-1]->location->[0];
    }
    # diag("get_pm_subs: $check_file" . Dumper(\%results));
    return %results ? \%results : undef;
}

sub _get_self_name_space {
    my ($repo_path) = @_;
    my $cmd = "find lib/BOM/* -maxdepth 0";
    $cmd = "cd $repo_path; " . $cmd if $repo_path;
    my %self_contain_pm;
    my @result = _run_command($cmd);
    foreach my $pm (@result) {
        $pm =~ s/lib\/BOM\//BOM::/;
        $pm =~ s/[.]pm//;
        $self_contain_pm{$pm} = 1;
    }
    @result = sort keys %self_contain_pm;
    return @result;
}

sub _is_skipped_file {
    my ($check_file, $skipped_files) = @_;
    return unless @$skipped_files;
    return grep { $check_file =~ /$_/ } @$skipped_files;
}

sub _run_command {
    my @command = @_;
    die "command cannot be empty!\n" unless @command;
    my $cmd = $command[0];
    if (@command > 1) {
        $cmd = join(' ', @command);
    }
    diag("running $cmd");
    my @result = qx/$cmd/;
    @result = map { chomp; $_ } @result;
    return @result;
}

1;
