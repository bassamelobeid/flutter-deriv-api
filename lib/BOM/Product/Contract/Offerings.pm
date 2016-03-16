package BOM::Product::Contract::Offerings;

=head1 NAME

BOM::Product::Contract::Offerings

=head1 DESCRIPTION

Help for getting insight into what is offered.

To be deprecated in favor of BOM::Product::Offerings

my $offerings = BOM::Product::Contract::Offerings->new;

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

=head2 tree

The data structure representing BOM offerings.

=cut

has landing_company => (
    is      => 'ro',
    default => 'costarica',
);

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

has date => (
    is      => 'ro',
    isa     => 'Date::Utility',
    default => sub { return Date::Utility->today },
);

has decorations => (
    is      => 'ro',
    default => sub { return [] },
    isa     => 'ArrayRef',
);

has times_cache => (
    is      => 'ro',
    default => sub { return {} },
);

has holidays_cache => (
    is      => 'ro',
    default => sub { return {} },
);

has c => (
    is  => 'ro',
    isa => 'Mojolicious::Controller',
);

my %known_decorations = (

    name => sub { return $_->translated_display_name },

    times => sub {
        my ($parent_obj, $self) = @_;
        my $exchange = $_->exchange;

        if (my $cached = $self->times_cache->{$exchange->symbol}) {
            return $cached;
        }

        my $times;
        my $no_data        = '--';
        my $display_method = 'time_hhmmss';
        $times = {
            open       => [],
            close      => [],
            settlement => $no_data
        };
        if (my $open = $exchange->opening_on($self->date)) {
            push @{$times->{open}}, $open->$display_method;
            my @closes;
            push @closes, $exchange->closing_on($self->date);
            $times->{settlement} = $exchange->settlement_on($self->date)->$display_method;
            if (my $breaks = $exchange->trading_breaks($self->date)) {
                for my $break (@$breaks) {
                    push @{$times->{open}}, $break->[-1]->$display_method;
                    push @closes, $break->[0];
                }
            }
            @{$times->{close}} = map { $_->$display_method } sort { $a->epoch <=> $b->epoch } @closes;
        }
        push @{$times->{open}},  $no_data if not @{$times->{open}};
        push @{$times->{close}}, $no_data if not @{$times->{close}};
        $self->times_cache->{$exchange->symbol} = $times;

        return $times;
    },

    events => sub {
        my ($parent_obj, $self) = @_;
        my $exchange = $_->exchange;
        my @events;

        if (my $cached = $self->holidays_cache->{$exchange->symbol}) {
            @events = @$cached;
        } else {
            my $today               = Date::Utility->today;
            my $trading_day         = $exchange->trading_date_for($self->date);
            my $how_long            = $today->days_in_month;
            my $date_display_method = 'date';
            my %seen_rules;
            foreach my $day (0 .. $how_long) {
                my $when = $trading_day->plus_time_interval($day . 'd');
                # Assumption is these are all mutually exclusive.
                # If you would both open late and close early, you'd make it a holiday.
                # If you have a holiday you wouldn't open or close at all.
                # Put a note here when you discover the exception.
                my ($rule, $message);
                my $change_rules = $exchange->regularly_adjusts_trading_hours_on($when);
                if ($exchange->closes_early_on($when)) {
                    $rule = $change_rules->{daily_close}->{rule};
                    $message =
                          $self->c
                        ? $self->c->l('Closes early (at [_1])', $exchange->closing_on($when)->time_hhmm)
                        : 'Closes early (at ' . $exchange->closing_on($when)->time_hhmm . ')';
                } elsif ($exchange->opens_late_on($when)) {
                    $rule = $change_rules->{daily_open}->{rule};
                    $message =
                          $self->c
                        ? $self->c->l('Opens late (at [_1])', $exchange->opening_on($when)->time_hhmm)
                        : 'Opens late (at ' . $exchange->opening_on($when)->time_hhmm . ')';
                } elsif ($exchange->has_holiday_on($when)) {
                    $message = $exchange->holidays->{$when->days_since_epoch};
                }
                if ($message) {
                    # This would be easier here with a hash, but then they might end up out of order.
                    # I'd rather deal with that here than in TT.

                    my $where = first_index { $_->{descrip} eq $message } @events;
                    # first_index returns -1 for not found.  Idiots.
                    my $explain = $rule // $when->$date_display_method;
                    if ($where != -1) {
                        $events[$where]->{dates} .= ', ' . $explain unless ($rule && $explain eq $rule && $seen_rules{$rule});
                    } else {
                        if ($when->is_same_as($trading_day) and $trading_day->is_same_as($today)) {
                            $explain = $self->c ? $self->c->l('today') : 'today';
                        }
                        push @events,
                            {
                            descrip => $message,
                            dates   => $explain,
                            };
                    }
                    $seen_rules{$rule} = 1 if ($rule and $explain eq $rule);
                }
                $self->holidays_cache->{$exchange->symbol} = \@events;
            }
        }
        return \@events;
    },

);

# This is not fully generalized enough to become its own object, yet.
# The "tree" should be able produce different representations of itself, say HashRef or JSON and have
# filtering by levels, removal of "obj", and clonability.
# But this suffices for our purposes here.

sub _build_tree {
    my $self = shift;

    my $tree = [];

    foreach my $market (
        sort { $a->display_order <=> $b->display_order }
        map { BOM::Market::Registry->instance->get($_) } get_offerings_with_filter('market', {landing_company => $self->landing_company}))
    {
        my $children    = [];
        my $market_info = {
            obj        => $market,
            submarkets => $children,
            children   => $children,
        };
        foreach my $submarket (
            sort { $a->display_order <=> $b->display_order }
            map  { BOM::Market::SubMarket::Registry->instance->get($_) } get_offerings_with_filter(
                'submarket',
                {
                    market          => $market->name,
                    landing_company => $self->landing_company
                }))
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
                map  { BOM::Market::Underlying->new($_) } get_offerings_with_filter(
                    'underlying_symbol',
                    {
                        submarket       => $submarket->name,
                        landing_company => $self->landing_company
                    }))
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
                    map  { BOM::Product::Contract::Category->new($_) } get_offerings_with_filter(
                        'contract_category',
                        {
                            underlying_symbol => $ul->symbol,
                            landing_company   => $self->landing_company
                        }))
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
                my $sub = (ref $func ? $func : $known_decorations{$func}) || next;
                local $_ = $item->{obj};
                $item->{$as} = $sub->($item->{parent_obj}, $self);
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

1;

