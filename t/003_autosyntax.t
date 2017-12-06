use strict;

use Test::More;
use Test::Syntax::Aggregate;
use File::Find::Rule;
use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use Test::Strict;
use Cwd;

my $pattern = $ARGV[0];        # confines test to just files matching this pattern.
my $PATH    = Cwd::abs_path;

my $used_modules = `grep -Phor "use \\K\\w*::[\\w:]*" $PATH | grep -v Moose| grep -v BOM::Test|sort|uniq`;

my @preload_modules = split "\n", $used_modules;

my $exclude_from_check_scripts = qr/PlackApp|StaffPages/;

my @scripts = sort grep { $_ =~ /$pattern/ unless not $pattern } File::Find::Rule->file->name(qr/\.p[lm]|\.cgi$/)->in($PATH);

subtest 'Run syntax check on all modules' => sub {
    check_scripts_syntax(
        preload       => [@preload_modules],
        scripts       => [grep { $_ !~ /$exclude_from_check_scripts/ } @scripts],
        hide_warnings => 1,
    );
    syntax_ok($_) for grep { /$exclude_from_check_scripts/ } @scripts;
};

subtest 'Run perl critic on all modules' => sub {
    all_critic_ok(@scripts);
};

done_testing;
