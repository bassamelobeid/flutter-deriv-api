package BOM::Product::ContractFactory;

use strict;
use warnings;

=head1 NAME

BOM::Product::ContractFactory

=head1 DESCRIPTION

Some general utility subroutines related to bet parameters.

=cut

use Carp qw( croak );
use Cache::RedisDB;
use List::Util qw( first );
use Time::Duration::Concise;
use VolSurface::Utils qw(get_strike_for_spot_delta);
use YAML::XS qw(LoadFile);

use BOM::Market::Data::Tick;
use BOM::Platform::Context qw(request);
use BOM::Product::ContractFactory::Parser qw(
    shortcode_to_parameters
    financial_market_bet_to_parameters
);

use base qw( Exporter );
our @EXPORT_OK = qw( produce_contract make_similar_contract simple_contract_info );

# pre-load modules
require BOM::Product::Contract::Asiand;
require BOM::Product::Contract::Asianu;
require BOM::Product::Contract::Call;
require BOM::Product::Contract::Calle;
require BOM::Product::Contract::Pute;
require BOM::Product::Contract::Digitdiff;
require BOM::Product::Contract::Digiteven;
require BOM::Product::Contract::Digitmatch;
require BOM::Product::Contract::Digitodd;
require BOM::Product::Contract::Digitover;
require BOM::Product::Contract::Digitunder;
require BOM::Product::Contract::Expirymisse;
require BOM::Product::Contract::Expiryrangee;
require BOM::Product::Contract::Expirymiss;
require BOM::Product::Contract::Expiryrange;
require BOM::Product::Contract::Invalid;
require BOM::Product::Contract::Notouch;
require BOM::Product::Contract::Onetouch;
require BOM::Product::Contract::Put;
require BOM::Product::Contract::Range;
require BOM::Product::Contract::Spreadd;
require BOM::Product::Contract::Spreadu;
require BOM::Product::Contract::Upordown;
require BOM::Product::Contract::Vanilla_call;
require BOM::Product::Contract::Vanilla_put;

=head2 produce_contract

Produce a Contract Object from a set of parameters

=cut

my %OVERRIDE_LIST = (
    INTRADU => {
        bet_type            => 'CALL',
        is_forward_starting => 1
    },
    INTRADD => {
        bet_type            => 'PUT',
        is_forward_starting => 1
    },
    FLASHU => {
        bet_type     => 'CALL',
        is_intraday  => 1,
        expiry_daily => 0
    },
    FLASHD => {
        bet_type     => 'PUT',
        is_intraday  => 1,
        expiry_daily => 0
    },
    DOUBLEUP => {
        bet_type     => 'CALL',
        is_intraday  => 0,
        expiry_daily => 1
    },
    DOUBLEDOWN => {
        bet_type     => 'PUT',
        is_intraday  => 0,
        expiry_daily => 1
    },
);

my $contract_type_config = LoadFile('/home/git/regentmarkets/bom/config/files/contract_types.yml');

sub produce_contract {
    my ($build_arg, $maybe_currency, $maybe_sold) = @_;

    my $params_ref = _args_to_ref($build_arg, $maybe_currency, $maybe_sold);

    # dereference here
    my %input_params = %$params_ref;

    if (my $missing = first { not defined $input_params{$_} } (qw(bet_type currency))) {
        # Some things are required for all possible contracts
        # This list is pretty small, though!
        croak $missing. ' is required.';
    }

    # common initialization for spreads and derivatives
    if (defined $OVERRIDE_LIST{$input_params{bet_type}}) {
        my $override_params = $OVERRIDE_LIST{$input_params{bet_type}};
        $input_params{$_} = $override_params->{$_} for keys %$override_params;
    }

    $input_params{bet_type} = 'LEGACY' unless exists $contract_type_config->{$input_params{bet_type}};
    my %type_config = %{$contract_type_config->{$input_params{bet_type}}};
    @input_params{keys %type_config} = values %type_config;

    my $contract_class;
    my $bet_type = ucfirst lc $input_params{bet_type};
    if (
        grep { /^$bet_type$/ }
        qw/
        Expiryrangee Expirymisse Calle Pute Asiand Asianu Call Digitdiff Digiteven Digitmatch Digitodd Digitover Digitunder Expirymiss
        Expiryrange Notouch Onetouch Put Range Spreadd Spreadu Upordown Vanilla_call Vanilla_put
        /
        )
    {
        $contract_class = 'BOM::Product::Contract::' . $bet_type;
    } else {
        $contract_class = 'BOM::Product::Contract::Invalid';
    }

    # We might need this for build so, pre-coerce;
    if ((ref $input_params{underlying}) !~ /BOM::Market::Underlying/) {
        $input_params{underlying} = BOM::Market::Underlying->new($input_params{underlying});
    }
    # If they gave us a date for start and pricing, then we need to do some magic.
    if (defined $input_params{date_pricing}) {
        my $pricing = Date::Utility->new($input_params{date_pricing});
        $input_params{underlying} = BOM::Market::Underlying->new($input_params{underlying}->symbol, $pricing)
            if (not($input_params{underlying}->for_date and $input_params{underlying}->for_date->is_same_as($pricing)));
    }

    my $contract_obj;
    if ($input_params{category} eq 'spreads') {
        $input_params{date_start} = Date::Utility->new if not $input_params{date_start};
        for (grep { defined $input_params{$_} } qw(stop_loss stop_profit)) {
            # copy them to supplied, we will build stop_loss & stop_profit later
            $input_params{'supplied_' . $_} = $input_params{$_};
            delete $input_params{$_};
        }
        $input_params{build_parameters} = {%input_params};
        $contract_obj = $contract_class->new(\%input_params);
    } else {
        delete $input_params{expiry_daily};
        if (not $input_params{date_start}) {
            # An undefined or missing date_start implies that we want a bet which starts now.
            $input_params{date_start} = Date::Utility->new;
            # Force date_pricing to be similarly set, but make sure we know below that we did this, for speed reasons.
            $input_params{pricing_new} = 1;
        }
        # Still need the available amount_types somewhere visible.
        my @available_amount_types = qw(payout stake);
        foreach my $at (@available_amount_types) {
            delete $input_params{$at} if ($input_params{amount_type});    # looks like ambiguous hash ref reuse.
                                                                          # Use the amount_type and make them work it out.
            if ($input_params{$at}) {
                # Support pre-stake parameters and how people might think it should work.
                $input_params{amount_type} = $at;                         # Replace these wholesale.
                $input_params{amount}      = $input_params{$at};
                delete $input_params{$at};
            }
        }
        if (defined $input_params{amount} && first { $_ eq $input_params{amount_type} } (@available_amount_types)) {
            if ($input_params{amount_type} eq 'payout') {
                $input_params{payout} = $input_params{amount};
            } elsif ($input_params{amount_type} eq 'stake') {
                $input_params{ask_price} = $input_params{amount};
            }
        } else {
            # Dunno what this is, so set the payout to zero and let it fail validation.
            $input_params{payout} = 0;
        }

        $input_params{date_start} = Date::Utility->new($input_params{date_start});

        if (defined $input_params{tick_expiry}) {
            $input_params{date_expiry} = $input_params{date_start}->plus_time_interval(2 * $input_params{tick_count});
        }

        if (defined $input_params{duration}) {
            if (my ($number_of_ticks) = $input_params{duration} =~ /(\d+)t$/) {
                $input_params{tick_expiry} = 1;
                $input_params{tick_count}  = $number_of_ticks;
                $input_params{date_expiry} = $input_params{date_start}->plus_time_interval(2 * $input_params{tick_count});
            } else {
                # The thinking here is that duration is only added on purpose, but
                # date_expiry might be hanging around from a poorly reused hashref.
                my $duration    = $input_params{duration};
                my $underlying  = $input_params{underlying};
                my $start_epoch = $input_params{date_start}->epoch;
                my $expiry;
                if ($duration =~ /d$/) {
                    # Since we return the day AFTER, we pass one day ahead of expiry.
                    my $expiry_date = Date::Utility->new($start_epoch)->plus_time_interval($duration);
                    # Daily bet expires at the end of day, so here you go
                    if (my $closing = $underlying->exchange->closing_on($expiry_date)) {
                        $expiry = $closing->epoch;
                    } else {
                        $expiry = $expiry_date->epoch;
                        my $regular_day   = $underlying->exchange->regular_trading_day_after($expiry_date);
                        my $regular_close = $underlying->exchange->closing_on($regular_day);
                        $expiry = Date::Utility->new($expiry_date->date_yyyymmdd . ' ' . $regular_close->time_hhmmss)->epoch;
                    }
                } else {
                    $expiry = $start_epoch + Time::Duration::Concise->new(interval => $duration)->seconds;
                }
                $input_params{date_expiry} = Date::Utility->new($expiry);
            }
        }
        $input_params{date_start}  //= 1;    # Error conditions if it's not legacy or run, I guess.
        $input_params{date_expiry} //= 1;

        $input_params{date_expiry} = Date::Utility->new($input_params{date_expiry});

        # This convenience which may also be a bad idea, but it makes testing easier.
        # You may also add hit and exit, if you like, but those seem like even worse ideas.
        foreach my $which (qw(current entry)) {
            my ($spot, $tick) = ($which . '_spot', $which . '_tick');
            next unless ($input_params{$spot} and not $input_params{$tick});

            $input_params{$tick} = BOM::Market::Data::Tick->new({
                quote  => $input_params{$spot},
                epoch  => 1,                                   # Intentionally very old for recognizability.
                symbol => $input_params{underlying}->symbol,
            });
            delete $input_params{$spot};
        }

        my @barriers = qw(barrier high_barrier low_barrier);
        foreach my $barrier_name (grep { defined $input_params{$_} } @barriers) {
            my $possible = $input_params{$barrier_name};
            if (ref($possible) !~ /BOM::Product::Contract::Strike/) {
                my $barrier_string_name = 'supplied_' . $barrier_name;
                if ($possible && (uc(substr($possible, -1)) eq 'D')) {
                    $input_params{'supplied_delta_' . $barrier_name} = $possible;
                    # They gave us a delta instead of a Strike string
                    substr($possible, -1, 1, '');    # Now just the number.
                    my $underlying = $input_params{underlying};
                    # A close enough approximation if they are using deltas.
                    my $tid  = Time::Duration::Concise->new(interval => $input_params{date_expiry}->epoch - $input_params{date_start}->epoch)->days;
                    my $tiy  = $tid / 365;
                    my $tick = $input_params{entry_tick} // $underlying->tick_at($input_params{date_start}, {allow_inconsistent => 1});
                    $input_params{$barrier_string_name} = get_strike_for_spot_delta({
                        delta            => $possible,
                        option_type      => 'VANILLA_CALL',
                        atm_vol          => 0.10,                                                       # Everything here is an approximation.
                        t                => $tiy,
                        r_rate           => ($tid > 1) ? $underlying->interest_rate_for($tiy) : 0,
                        q_rate           => ($tid > 1) ? $underlying->dividend_rate_for($tiy) : 0,
                        spot             => $tick->quote,
                        premium_adjusted => $underlying->market_convention->{delta_premium_adjusted},
                    });
                } else {
                    # Some sort of string which Strike can presumably use.
                    $input_params{$barrier_string_name} = $possible;
                }
                delete $input_params{$barrier_name};
            }
        }

        # just to make sure that we don't accidentally pass in undef barriers
        delete $input_params{$_} for @barriers;

        $input_params{'build_parameters'} = {%input_params};    # Do not self-cycle.

        # This occurs after to hopefully make it more annoying to bypass the Factory.
        $input_params{'_produce_contract_ref'} = \&produce_contract;

        $contract_obj = $contract_class->new(\%input_params);
    }

    return $contract_obj;
}

sub _args_to_ref {
    my ($build_arg, $maybe_currency, $maybe_sold) = @_;

    my $params_ref =
          (ref $build_arg eq 'HASH') ? $build_arg
        : ((ref $build_arg) =~ /BOM::Database::Model::FinancialMarketBet/) ? financial_market_bet_to_parameters($build_arg, $maybe_currency)
        : (defined $build_arg) ? shortcode_to_parameters($build_arg, $maybe_currency, $maybe_sold)
        :                        undef;

    # After all of that, we should have gotten a hash reference.
    die 'Improper arguments to produce_contract.' unless (ref $params_ref eq 'HASH');

    return $params_ref;
}

=head2 simple_contract_info

To avoid doing a bunch of extra work hitting the FeedDB, this fakes up an entry tick and returns a description,
tick_expiry status and spread status only. These values are cached when accessed via a shortcode.

This whole thing needs to be reconsidered, eventually.

=cut

{
    my $sci_keyspace = 'SIMPLE_CONTRACT_INFO';
    my $sci_ttl      = 24 * 60 * 60;             # Tune for cache retention to manage space/time trade-off.

    sub simple_contract_info {
        my ($build_arg, $maybe_currency) = @_;

        # If this looks like it may be a shortcode (which is the most common case)
        # we can try to use the cache.
        my $cache_key =
            ($maybe_currency && !ref($build_arg))
            ? join(';', $build_arg, $maybe_currency, BOM::Platform::Context::request()->language)
            : undef;
        my $result = ($cache_key) ? Cache::RedisDB->get($sci_keyspace, $cache_key) : undef;

        if (not $result) {
            # Uncacheable or cache miss, so we do the full routine.
            my $params = _args_to_ref($build_arg, $maybe_currency);
            $params->{entry_tick} = BOM::Market::Data::Tick->new({
                quote => 1,
                epoch => 1,
            });
            my $contract_analogue = produce_contract($params);
            $result = [$contract_analogue->longcode, $contract_analogue->tick_expiry, $contract_analogue->is_spread];
            Cache::RedisDB->set($sci_keyspace, $cache_key, $result, $sci_ttl) if ($cache_key);
        }

        return ($result) ? @$result : undef;
    }
}

=head2 make_similar_contract

Produce a Contract Object from an example contract with one or more parameters changed.

The second argument should be the contract for which you wish to produce a similar contract.
The changes should be in a hashref as the second argument.

Set 'as_new' to create a similar contract which starts "now"
Set 'for_sale' to convert an extant contract for sale at market.
Set 'priced_at' to move to a particular point in the contract lifetime. 'now' and 'start' are short-cuts.
Otherwise, the changes should be attribute to fill on the contract as with produce_contract
=cut

sub make_similar_contract {
    my ($orig_contract, $changes) = @_;

    # Start by making a copy of the parameters we used to build this bet.
    my %build_parameters = %{$orig_contract->build_parameters};

    if ($changes->{as_new}) {
        if (!$orig_contract->is_spread) {
            if ($orig_contract->two_barriers) {
                $build_parameters{high_barrier} = $orig_contract->high_barrier->supplied_barrier if $orig_contract->high_barrier;
                $build_parameters{low_barrier}  = $orig_contract->low_barrier->supplied_barrier  if $orig_contract->low_barrier;
            } else {
                $build_parameters{barrier} = $orig_contract->barrier->supplied_barrier if (defined $orig_contract->barrier);
            }
        }
        delete $build_parameters{date_start};
    }
    delete $changes->{as_new};
    if ($changes->{for_sale}) {
        $build_parameters{require_entry_tick_for_sale} = 1;
    }
    delete $changes->{for_sale};
    if (my $when = $changes->{priced_at}) {
        if ($when eq 'now') {
            delete $build_parameters{date_pricing};
        } else {
            $when = $orig_contract->date_start if ($when eq 'start');
            $build_parameters{date_pricing} = $when;
        }
    }
    delete $changes->{priced_at};

    # Sooner or later this should have some more knowledge of what can and
    # should be built, but for now we use this naive parameter switching.
    foreach my $key (%$changes) {
        $build_parameters{$key} = $changes->{$key};
    }

    return produce_contract(\%build_parameters);
}

1;
