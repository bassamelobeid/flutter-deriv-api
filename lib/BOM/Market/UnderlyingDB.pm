package BOM::Market::UnderlyingDB;

use strict;
use warnings;
our $VERSION = 0.01;

use MooseX::Singleton;
extends 'Finance::Asset';    # A temporary measure during the move.

=head1 NAME

BOM::Market::UnderlyingDB

=head1 SYNOPSYS

    my $udb     = BOM::Market::UnderlyingDB->instance;
    my @symbols = $udb->get_symbols_for(
        market            => 'stocks',
        contract_category => 'endsinout',
        expiry_type       => 'intraday',
        broker            => 'CR',
    );
    my $sym_props = $udb->get_parameters_for('frxEURUSD');

=head1 DESCRIPTION

This module implements functions to access information from underlyings.yml.
The class is a singleton. You do not need to explicitely initialize class,
it will be initialized automatically then you will try to get instance. By
default it reads information from underlyings.yml. It periodically checks
if underlyings.yml was changed and if it is reloads data.

=cut

use namespace::autoclean;
use List::Util qw(first);
use List::MoreUtils qw( uniq );
use Memoize;

use BOM::Utility::Log4perl qw( get_logger );
use BOM::Market::Registry;
use BOM::Market::SubMarket::Registry;
use BOM::Market::SubMarket;
use BOM::Market::Underlying;

has _file_content => (
    is      => 'ro',
    default => sub { return Finance::Asset->instance->all_parameters; },
);

=head2 $self->symbols_for_intraday_fx

The standard list of non RMG underlyings which have active bets anywhere.

Convenience wrapper for get_symbols_for

=cut

sub symbols_for_intraday_fx {
    my $self = shift;

    return $self->get_symbols_for(
        market            => [qw(forex commodities)],
        contract_category => 'callput',
        expiry_type       => 'intraday',
        start_type        => 'spot',
    );
}

=head2 symbols_for_intraday_index

The list of index that has intraday contracts.

=cut

sub symbols_for_intraday_index {
    my $self = shift;
    my @symbols;
    @symbols = $self->get_symbols_for(
        market            => 'indices',
        contract_category => 'callput',
        expiry_type       => 'intraday',
        start_type        => 'spot',
    );

    push @symbols,
        $self->get_symbols_for(
        market    => 'indices',
        submarket => 'smart_index'
        );

    return @symbols;
}

=head2 markets

Return list of all markets

=cut

sub markets {
    my $self = shift;
    my @markets =
        map { $_->name } BOM::Market::Registry->instance->display_markets;
    return @markets;
}

=head2 $self->get_symbols_for(%filter_args)

Return list of symbols satisfying given conditions. You can specify following I<%filter_args>:

=over 4

=item market

Return only symbols for given market. This argument is required. This argument
may be array refference if you want to get symbols for several markets.

=item submarket

Return only symbols for the given submarket.  This is optional.  Specifying a
miatched market and submarket will result in an empty response

=item contract_category

Return only symbols for which given contract_category is available. contract_category may be one
of the returned by the available_contract_categories function, or "IV" which means
at least one of the callput, endsinout, touchnotouch, staysinout, or "ANY"
which means that some contract_categories should be enabled for symbol. If contract_category
is not specified, function will return all symbols for given market including
the inactive ones (for which not any bet types available).

=item expiry_type

Return only those symbols which match both the bet type and the supplied expiry_type

=item broker

Changes filter behaviour to look or not to look onto contract_categories available for
virtual accounts. By default VRTC is assumed.

=item exclude_disabled

Changes filter behavior to disallow listing of symbols which have buying/trading suspended.

=back

=cut

sub get_symbols_for {
    my ($self, %args) = @_;
    get_logger->logdie("market is not specified!" . Carp::longmess)
        unless $args{market};

    $args{contract_category} = $args{contract_category}->code
        if (ref $args{contract_category});

    my @underlyings;
    my %disabled;
    if ($args{exclude_disabled}) {
        my $ul_info = BOM::Platform::Runtime->instance->app_config->quants->underlyings;
        %disabled = map { $_ => 1 } uniq(@{$ul_info->suspend_buy}, @{$ul_info->suspend_trades});
    }
    my $markets = ref $args{market} ? $args{market} : [$args{market}];
    for (@$markets) {
        $args{market} = $_;
        foreach my $symbol ($self->_get_symbols_for(%args)) {
            push @underlyings, $symbol unless ($disabled{$symbol});
        }
    }

    return @underlyings;
}

sub _get_symbols_for {
    my ($self, %args) = @_;
    foreach my $any_is_default (qw(expiry_type submarket)) {
        delete $args{$any_is_default}
            if ($args{$any_is_default} and $args{$any_is_default} eq 'ANY');
    }

    die 'Cannot specify expiry_type without specifying contract_category'
        if ($args{expiry_type} and not $args{contract_category});

    if ($args{expiry_type}
        and not first { $args{expiry_type} eq $_ } $self->available_expiry_types)
    {
        die 'Supplied expiry_type[' . $args{expiry_type} . '] is not listed in available_expiry_types';
    }

    if ($args{start_type}
        and not first { $args{start_type} eq $_ } $self->available_start_types)
    {

        die 'Supplied start_type[' . $args{start_type} . '] is not listed in available_start_types';
    }

    my @current_list =
        grep { $_->market->name eq $args{market} } map { BOM::Market::Underlying->new($_->{symbol}) } values %{$self->_file_content};
    if (defined $args{submarket}) {
        my @submarket = ref $args{submarket} ? @{$args{submarket}} : ($args{submarket});
        my @new_list;
        foreach my $sub (@submarket) {
            push @new_list, grep { $_->submarket->name eq $sub } @current_list;
        }
        @current_list = @new_list;
    }

    if ($args{quanto_only}) {
        @current_list = grep { $_->quanto_only } @current_list;
    } elsif ($args{contract_category}) {
        @current_list = grep { !$_->quanto_only } @current_list;

        $args{broker} = 'VRTC' unless $args{broker};

        my $contract_categories =
              ($args{contract_category} eq 'ANY') ? [$self->available_contract_categories]
            : ($args{contract_category} eq 'IV')  ? [$self->available_iv_categories]
            :                                       [$args{contract_category}];

        my $expiry_types =
              ($args{expiry_type})
            ? [$args{expiry_type}]
            : [$self->available_expiry_types];
        my $start_types =
              ($args{start_type})
            ? [$args{start_type}]
            : [$self->available_start_types];
        my $barrier_categories =
              ($args{barrier_category})
            ? [$args{barrier_category}]
            : [$self->available_barrier_categories];

        @current_list = grep { (_matches_types($_, $expiry_types, $start_types, $contract_categories, $barrier_categories)) } @current_list;
    }

    return map { $_->symbol } @current_list;
}

memoize('_get_symbols_for', NORMALIZER => '_normalize_method_args');

sub _matches_types {
    my ($ul, $expiry_types, $start_types, $contract_categories, $barrier_categories) = @_;

    my $found;

    if (my $checkref = {%{$ul->contracts}}) {
        SEARCH:
        for (my $i = 0; $i < scalar(@$expiry_types); $i++) {
            my $expiry_type = $expiry_types->[$i];
            for (my $j = 0; $j < scalar(@$start_types); $j++) {
                my $start_type = $start_types->[$j];
                foreach my $barrier_category (@{$barrier_categories}) {
                    $found = first { $checkref->{$_}->{$expiry_type}->{$start_type}->{$barrier_category} } @$contract_categories;
                    last SEARCH if ($found);
                }
            }
        }
    }
    return $found;
}

sub _normalize_method_args {
    my ($self, %args) = @_;
    return join "\0", map { $_ => $args{$_} } sort keys %args;
}

__PACKAGE__->meta->make_immutable(inline_constructor => 0);

1;
