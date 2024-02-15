use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Array::Utils qw(array_minus);

use BOM::Config;

subtest 'is hierarchy valid (every child should have one parent) and no cycles' => sub {
    my $hierarchy_g = BOM::Config->status_hierarchy()->{hierarchy};

    sub has_cycle {
        my ($hierarchy) = @_;
        my %visited;
        foreach my $node (keys %$hierarchy) {
            return 1 if _has_cycle($hierarchy, $node, \%visited);
        }
        return 0;
    }

    sub _has_cycle {
        my ($hierarchy, $node, $visited) = @_;
        return 1 if defined $visited->{$node} && $visited->{$node} eq 1;
        return 0 if defined $visited->{$node} && $visited->{$node} eq 2;
        $visited->{$node} = 1;
        my %hierarchy_copy = %$hierarchy;
        foreach my $child (@{$hierarchy_copy{$node}}) {
            return 1 if _has_cycle($hierarchy, $child, $visited);
        }
        $visited->{$node} = 2;
        return 0;
    }

    sub has_multiple_parents {
        my ($hierarchy) = @_;
        my %parents;
        foreach my $node (keys %$hierarchy) {
            foreach my $child (@{$hierarchy->{$node}}) {
                return 1 if $parents{$child}++;
            }
        }
        return 0;
    }

    sub has_two_levels_only {
        my ($hierarchy) = @_;
        my @parents     = keys %$hierarchy;
        my @children    = map { @$_ } values %$hierarchy;

        # Since having two levels means that no parent can be a child of another parent
        return array_minus(@children, @parents) eq @children;

    }

    ok !has_cycle($hierarchy_g),            'hierarchy has no cycles';
    ok !has_multiple_parents($hierarchy_g), 'No child has multiple parents';
    ok has_two_levels_only($hierarchy_g),   'Hierarchy has two levels only';

    $hierarchy_g = {
        'A' => ['B'],
        'B' => ['A'],
    };

    ok has_cycle($hierarchy_g), 'hierarchy has cycles';
};

done_testing;
