use strict;

use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use File::Find::Rule;
use Cwd;

=pod

=head1 SYNOPSIS

This test file checks all the B<pm> and B<pl> files against perl L<Test::Perl::Critic>.

=cut

my $pattern = $ARGV[0] // '';
my $rule    = File::Find::Rule->new;
my @rules   = ($rule->new->name(qr/\.p[lm]$/));

unshift @rules, $rule->new->name(qr/$pattern/)->prune->discard if $pattern;
all_critic_ok($rule->or(@rules)->in(Cwd::abs_path . '/lib'));
