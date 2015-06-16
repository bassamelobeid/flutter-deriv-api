package BOM::Product::Contract::Offerings;

=head1 NAME

BOM::Product::Contract::Offerings

=head1 DESCRIPTION

Help for getting insight into what is offered.

To be deprecated in favor of BOM::Product::Offerings

my $offerings = BOM::Product::Contract::Offerings->new(broker_code => 'CR');

=cut

use Moose;
use namespace::autoclean;

use List::MoreUtils qw(uniq first_index);

use BOM::Market::Registry;
use BOM::Market::Underlying;
use BOM::Product::Contract::Category;
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Market;
use BOM::Market::SubMarket;
use BOM::Market::SubMarket::Registry;
use BOM::Product::Types;
use Cache::RedisDB;
use BOM::Platform::Context qw(request);

=head1 ATTRIBUTES

=head2 broker_code

The broker code for which these offerings apply.

Required

=cut

has broker_code => (
    is       => 'ro',
    isa      => 'bom_broker_code',
    required => 1,
);

=head2 tree

The data structure representing BOM offerings.

=cut

has tree => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 levels

Text description of what is at each level, which is also the identifier for the
placement in the level previous, if any.

=cut

has levels => (
    is       => 'ro',
    init_arg => undef,
    default  => sub {
        return [qw(markets submarkets underlyings contract_categories )];
    },

);

# This is not fully generalized enough to become its own object, yet.
# The "tree" should be able produce different representations of itself, say HashRef or JSON and have
# filtering by levels, removal of "obj", and clonability.
# But this suffices for our purposes here.

sub _build_tree {
    my $self = shift;

    my @cache_info = ('OFFERINGS', $self->broker_code . '/' . request()->language);

    if (my $cached = Cache::RedisDB->get(@cache_info)) {
        return $cached;
    }

    my $tree = [];

    foreach my $market (
        sort { $a->display_order <=> $b->display_order }
        map  { BOM::Market::Registry->instance->get($_) } get_offerings_with_filter('market'))
    {
        my $children    = [];
        my $market_info = {
            obj        => $market,
            submarkets => $children,
            children   => $children,
        };
        foreach my $submarket (
            sort { $a->display_order <=> $b->display_order }
            map { BOM::Market::SubMarket::Registry->instance->get($_) } get_offerings_with_filter('submarket', {market => $market->name}))
        {
            my $children       = [];
            my $submarket_info = {
                obj         => $submarket,
                parent_obj  => $market,
                underlyings => $children,
                children    => $children,
                parent      => $market_info,
            };
            foreach my $ul (
                sort { $a->translated_display_name() cmp $b->translated_display_name() }
                map { BOM::Market::Underlying->new($_) } get_offerings_with_filter('underlying_symbol', {submarket => $submarket->name}))
            {
                my $children        = [];
                my $underlying_info = {
                    obj                 => $ul,
                    parent_obj          => $submarket,
                    contract_categories => $children,
                    children            => $children,
                    parent              => $submarket_info
                };
                foreach my $bc (
                    sort { $a->display_order <=> $b->display_order }
                    map  { BOM::Product::Contract::Category->new($_) }
                    get_offerings_with_filter('contract_category', {underlying_symbol => $ul->symbol}))
                {
                    my $children      = [];
                    my $category_info = {
                        obj        => $bc,
                        parent_obj => $ul,
                        children   => $children,
                        parent     => $underlying_info
                    };
                    push @{$underlying_info->{contract_categories}}, $category_info;
                }
                push @{$submarket_info->{underlyings}}, $underlying_info;
            }
            push @{$market_info->{submarkets}}, $submarket_info;
        }
        push @$tree, $market_info;
    }

    # This is always cached here before any decoration, which
    # make for easier reuse than a singleton would.

    # TODO: figure out why this might have attached code reference which
    # prevent serialization
    #Cache::RedisDB->set_nw(@cache_info, $tree, 89);

    return $tree;
}

=head1 decorate_tree

Decorates the tree with the supplied code ref as the given name at the level given.

Returns the tree with decorations applied.

=cut

sub decorate_tree {
    my ($self, %decorations) = @_;

    foreach my $level (keys %decorations) {
        foreach my $item (@{$self->get_items_on_level($level)}) {
            foreach my $as (keys %{$decorations{$level}}) {
                my $func = $decorations{$level}->{$as};
                local $_ = $item->{obj};
                $item->{$as} = $func->($item->{parent_obj});
            }
        }
    }

    return $self->tree;
}

sub get_items_on_level {
    my ($self, $level) = @_;
    my @levels = @{$self->levels};
    my $chosen_level = first_index { $_ eq $level } @levels;
    confess "Level $level must match one of those defined: " . join(', ', @levels)
        if ($chosen_level == -1);

    my $list = $self->tree;    # Start at the top of the list;
    for (my $i = 1; $i <= $chosen_level; $i++) {
        $list = [map { @{$_->{$levels[$i]}} } @$list];
    }

    return $list;
}

__PACKAGE__->meta->make_immutable;

=head1 LICENSE AND COPYRIGHT

Copyright 2013 RMG Technology (M) Sdn Bhd

=cut

1;
