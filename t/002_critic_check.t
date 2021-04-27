use strict;

use Test::Perl::Critic -profile => '/home/git/regentmarkets/cpan/rc/.perlcriticrc';
use File::Find::Rule;
use Cwd;

=pod

=head1 SYNOPSIS

This test file checks all the B<pm> and B<pl> files against perl L<Test::Perl::Critic>.

=head1 NOTE

We B<MUST> run this file with B<--norc> option, otherwise it will fail.

=cut

my $rule  = File::Find::Rule->new;
my @rules = ($rule->new->name(m!/WebsocketAPI/Tests/|/WebsocketAPI/Helpers/!)->prune->discard, $rule->new->name(qr/\.p[lm]$/));

all_critic_ok($rule->or(@rules)->in(Cwd::abs_path . '/lib'));
