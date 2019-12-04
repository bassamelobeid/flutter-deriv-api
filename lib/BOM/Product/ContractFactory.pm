package BOM::Product::ContractFactory;

use strict;
use warnings;

use Cache::RedisDB;
use List::Util qw(first any);
use Time::Duration::Concise;
use VolSurface::Utils qw(get_strike_for_spot_delta);
use YAML::XS qw(LoadFile);
use File::ShareDir;
use Try::Tiny;

use Postgres::FeedDB::Spot::Tick;
use LandingCompany::Registry;

use BOM::Product::Exception;
use BOM::Product::Categorizer;
use Finance::Contract::Longcode qw(
    shortcode_to_parameters
);

require UNIVERSAL::require;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Product::Role::Multibarrier;

use Exporter qw(import export_to_level);

BEGIN {
    our @EXPORT_OK = qw( produce_contract make_similar_contract produce_batch_contract );
}

use BOM::Product::Contract::Multup;
use BOM::Product::Contract::Multdown;
use BOM::Product::Contract::Batch;
use BOM::Product::Contract::Asiand;
use BOM::Product::Contract::Asianu;
use BOM::Product::Contract::Call;
use BOM::Product::Contract::Calle;
use BOM::Product::Contract::Pute;
use BOM::Product::Contract::Digitdiff;
use BOM::Product::Contract::Digiteven;
use BOM::Product::Contract::Digitmatch;
use BOM::Product::Contract::Digitodd;
use BOM::Product::Contract::Digitover;
use BOM::Product::Contract::Digitunder;
use BOM::Product::Contract::Expirymisse;
use BOM::Product::Contract::Expiryrangee;
use BOM::Product::Contract::Expirymiss;
use BOM::Product::Contract::Expiryrange;
use BOM::Product::Contract::Invalid;
use BOM::Product::Contract::Notouch;
use BOM::Product::Contract::Onetouch;
use BOM::Product::Contract::Put;
use BOM::Product::Contract::Range;
use BOM::Product::Contract::Upordown;
use BOM::Product::Contract::Vanilla_call;
use BOM::Product::Contract::Vanilla_put;
use BOM::Product::Contract::Lbfloatcall;
use BOM::Product::Contract::Lbfloatput;
use BOM::Product::Contract::Lbhighlow;
use BOM::Product::Contract::Callspread;
use BOM::Product::Contract::Putspread;
use BOM::Product::Contract::Tickhigh;
use BOM::Product::Contract::Ticklow;
use BOM::Product::Contract::Resetcall;
use BOM::Product::Contract::Resetput;
use BOM::Product::Contract::Runhigh;
use BOM::Product::Contract::Runlow;

=head2 produce_contract

Produce a Contract Object from a set of parameters

=cut

sub produce_contract {
    my ($build_arg, $maybe_currency, $maybe_sold) = @_;

    my $params_ref = {%{_args_to_ref($build_arg, $maybe_currency, $maybe_sold)}};

    $params_ref = BOM::Product::Categorizer->new(parameters => $params_ref)->get();

    _validate_input_parameters($params_ref);

    my $product_type = $params_ref->{product_type} // 'basic';
    $product_type =~ s/_//;

    my $role        = 'BOM::Product::Role::' . ucfirst lc $product_type;
    my $role_exists = $role->can('meta');

    # This occurs after to hopefully make it more annoying to bypass the Factory.
    $params_ref->{'_produce_contract_ref'} = \&produce_contract;

    my $contract_class = 'BOM::Product::Contract::' . ucfirst lc $params_ref->{bet_type};
    $params_ref->{payout} += 0 if $params_ref->{payout};
    return $contract_class->new($params_ref) unless $role_exists;

    # we're applying role. For speed reasons, we're not using $role->meta->apply($contract_obj),
    # but create an anonymous class with needed role. This is done only once and cached

    $params_ref->{build_parameters}{role} = $role;
    $contract_class = Moose::Meta::Class->create_anon_class(
        superclasses => [$contract_class],
        roles        => [$role],
        cache        => 1,
    );

    return $contract_class->new_object($params_ref);
}

sub produce_batch_contract {
    my $args = shift;

    # it is not nice to change the input parameters
    my $build_args = {%$args};

    # ideally we shouldn't be doing it here but the interface is not standardized!
    $build_args->{bet_types} = [$build_args->{bet_type}] if $build_args->{bet_type} and not $build_args->{bet_types};
    BOM::Product::Exception->throw(
        error_code => 'MissingRequiredContractParams',
        error_args => ['bet_type'],
        details    => {field => ''},
    ) if (not $build_args->{bet_types} or ref $build_args->{bet_types} ne 'ARRAY');

    BOM::Product::Exception->throw(
        error_code => 'InvalidBarrierUndef',
        details    => {field => ''},
    ) if (not $build_args->{barriers} or ref $build_args->{barriers} ne 'ARRAY');

    my @contract_parameters = ();
    my $contract_types      = delete $build_args->{bet_types};
    my $barriers            = delete $build_args->{barriers};

    foreach my $contract_type (@$contract_types) {
        foreach my $barrier (@$barriers) {
            my %params = %$build_args;
            $params{bet_type} = $contract_type;

            if (ref $barrier eq 'HASH') {
                if (exists $barrier->{barrier} and exists $barrier->{barrier2}) {
                    $params{supplied_high_barrier} = $barrier->{barrier};
                    $params{supplied_low_barrier}  = $barrier->{barrier2};
                } elsif (exists $barrier->{barrier}) {
                    $params{supplied_barrier} = $barrier->{barrier};
                }
            } else {
                $params{supplied_barrier} = $barrier;
            }

            push @contract_parameters, \%params;
        }
    }

    return BOM::Product::Contract::Batch->new(
        parameters           => \@contract_parameters,
        produce_contract_ref => \&produce_contract
    );
}

sub _validate_input_parameters {
    my $params = shift;

    return if $params->{bet_type} =~ /INVALID/i or $params->{for_sale};

    BOM::Product::Exception->throw(
        error_code => 'MissingRequiredContractParams',
        error_args => ['date_start'],
        details    => {field => 'date_start'},
    ) unless $params->{date_start};    # date_expiry is validated in BOM::Product::Categorizer

    BOM::Product::Exception->throw(
        error_code => 'MissingTradingPeriodStart',
        error_args => ['trading_period_start'],
        details    => {field => 'trading_period_start'},
    ) if (($params->{product_type} // '') eq 'multi_barrier' and not $params->{trading_period_start});

    if ($params->{category}->has_user_defined_expiry) {
        my $start  = Date::Utility->new($params->{date_start});
        my $expiry = Date::Utility->new($params->{date_expiry});

        BOM::Product::Exception->throw(
            error_code => 'SameExpiryStartTime',
            details    => {field => defined($params->{duration}) ? 'duration' : 'date_expiry'},
        ) if $start->epoch == $expiry->epoch;
        BOM::Product::Exception->throw(
            error_code => 'PastExpiryTime',
            details    => {field => 'date_expiry'},
        ) if $expiry->is_before($start);
    }

    # hard-coded svg because that's the widest offerings range we have.
    my $lc        = LandingCompany::Registry::get('svg');
    my $offerings = $lc->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config());

    my $us = $params->{underlying}->symbol;

    # these will be handled in validation later.
    return
           if $offerings->config->{suspend_trading}
        or $offerings->config->{disabled_markets}{$params->{underlying}->market->name}
        or $offerings->config->{suspend_trades}{$us}
        or $offerings->config->{suspend_buy}{$us};

    unless (any { $us eq $_ } $offerings->values_for_key('underlying_symbol')) {
        BOM::Product::Exception->throw(
            error_code => 'InvalidInputAsset',
            details    => {field => 'symbol'},
        );
    }

    return;
}

sub _args_to_ref {
    my ($build_arg, $maybe_currency, $maybe_sold) = @_;

    my $params_ref =
          (ref $build_arg eq 'HASH') ? $build_arg
        : (defined $build_arg) ? shortcode_to_parameters($build_arg, $maybe_currency, $maybe_sold)
        :                        undef;

    # After all of that, we should have gotten a hash reference.
    die 'Improper arguments to produce_contract.' unless (ref $params_ref eq 'HASH');

    return $params_ref;
}

=head2 make_similar_contract

Produce a Contract Object from an example contract with one or more parameters changed.

The second argument should be the contract for which you wish to produce a similar contract.
The changes should be in a hashref as the second argument.

Set 'as_new' to create a similar contract which starts "now"
Set 'priced_at' to move to a particular point in the contract lifetime. 'now' and 'start' are short-cuts.
Otherwise, the changes should be attribute to fill on the contract as with produce_contract
=cut

sub make_similar_contract {
    my ($orig_contract, $changes) = @_;

    # Start by making a copy of the parameters we used to build this bet.
    my %build_parameters = %{$orig_contract->build_parameters};

    if ($changes->{as_new}) {
        if ($orig_contract->two_barriers) {
            $build_parameters{high_barrier} = $orig_contract->high_barrier->supplied_barrier if $orig_contract->high_barrier;
            $build_parameters{low_barrier}  = $orig_contract->low_barrier->supplied_barrier  if $orig_contract->low_barrier;
        } else {
            $build_parameters{barrier} = $orig_contract->barrier->supplied_barrier if (defined $orig_contract->barrier);
        }
        delete $build_parameters{date_start};
    }
    delete $changes->{as_new};
    if (my $when = $changes->{priced_at}) {
        if ($when eq 'now') {
            delete $build_parameters{date_pricing};
        } else {
            $when = $orig_contract->date_start if ($when eq 'start');
            $build_parameters{date_pricing} = $when;
        }
    }
    delete $changes->{priced_at};

    # since we are only allowing either, we will remove $build_parameters{date_expiry}
    if ($changes->{duration} and $build_parameters{date_expiry}) {
        delete $build_parameters{date_expiry};
    }
    # Sooner or later this should have some more knowledge of what can and
    # should be built, but for now we use this naive parameter switching.
    foreach my $key (keys %$changes) {
        $build_parameters{$key} = $changes->{$key};
    }

    return produce_contract(\%build_parameters);
}

1;
