package BOM::Product::Categorizer;

use Moose;

use Date::Utility;
use YAML::XS qw(LoadFile);
use File::ShareDir;
use Scalar::Util::Numeric qw(isint);
use List::Util qw(first max);
use List::MoreUtils qw(none);
use LandingCompany::Offerings qw(get_contract_specifics);
use Postgres::FeedDB::Spot::Tick;
use Time::HiRes;

use BOM::Platform::Context qw(localize);
use BOM::Platform::Runtime;
use BOM::MarketData qw(create_underlying create_underlying_db);

my $contract_type_config = LoadFile(File::ShareDir::dist_file('LandingCompany', 'contract_types.yml'));

has parameters => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
);

has [qw(contract_types barriers)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_contract_types {
    my $self = shift;

    my $p = $self->parameters;

    my $c_types = $p->{bet_types} ? $p->{bet_types} : $p->{bet_type} ? [$p->{bet_type}] : die 'bet_type is required';

    return $c_types;
}

sub _build_barriers {
    my $self = shift;

    my $p = $self->parameters;

    return $p->{barriers} if $p->{barriers};

    # double barrier contract
    foreach my $pair (['high_barrier', 'low_barrier'], ['supplied_high_barrier', 'supplied_low_barrier']) {
        if (exists $p->{$pair->[0]} and exists $p->{$pair->[1]}) {
            return [{
                    barrier  => $p->{$pair->[0]},
                    barrier2 => $p->{$pair->[1]}}];
        }
    }

    foreach my $type ('barrier', 'supplied_barrier') {
        # single barrier contract
        if (exists $p->{$type}) {
            return [$p->{$type}];
        }
    }

    return [];
}

sub process {
    my $self = shift;

    my $c_types  = $self->contract_types;
    my $barriers = $self->barriers;

    my @params;
    my $contract_params = $self->_initialize_contract_parameters();

    foreach my $c_type (@$c_types) {
        $self->_initialize_contract_config($c_type, $contract_params);
        if (@$barriers) {
            foreach my $barrier (@$barriers) {
                $self->_initialize_barrier($barrier, $contract_params);
                $contract_params->{build_parameters} = {%$contract_params};
                push @params, $contract_params;
            }
        } else {
            # sometimes barriers could be undefined
            $contract_params->{build_parameters} = {%$contract_params};
            push @params, $contract_params;
        }
    }

    return scalar(@params) > 1 ? \@params : $params[0];
}

sub _initialize_contract_parameters {
    my $self = shift;

    my $pp = {%{$self->parameters}};

    # always build shortcode
    delete $pp->{shortcode};

    die 'currency is required'   unless $pp->{currency};
    die 'underlying is required' unless $pp->{underlying};

    # set date start if not given. If we want to price a contract starting now, date_start should never be provided!
    unless (defined $pp->{date_start}) {
        # An undefined or missing date_start implies that we want a bet which starts now.
        $pp->{date_start} = Date::Utility->new;
        # Force date_pricing to be similarly set, but make sure we know below that we did this, for speed reasons.
        $pp->{pricing_new} = 1;
    } else {
        $pp->{date_start} = Date::Utility->new($pp->{date_start});
    }

    foreach my $type (grep { defined $pp->{$_} } qw(date_pricing date_expiry)) {
        $pp->{$type} = Date::Utility->new($pp->{$type});
    }

    if (ref $pp->{underlying} ne 'Quant::Framework::Underlying') {
        $pp->{underlying} = create_underlying($pp->{underlying}, $pp->{date_pricing});
    }

    # If they gave us a date for start and pricing, then we need to do some magic.
    if ($pp->{date_pricing}) {
        if (not($pp->{underlying}->for_date and $pp->{underlying}->for_date->is_same_as($pp->{date_pricing}))) {
            $pp->{underlying} = create_underlying($pp->{underlying}->symbol, $pp->{date_pricing});
        }
    }

    $pp->{starts_as_forward_starting} //= 0;
    $pp->{landing_company}            //= 'costarica';

    # hash reference reusef
    delete $pp->{expiry_daily};
    delete $pp->{is_intraday};

    if (exists $pp->{stop_profit} and exists $pp->{stop_loss}) {
        # these are the only parameters for spreads
        $pp->{'supplied_' . $_} = delete $pp->{$_} for (qw(stop_profit stop_loss));
    } else {
        # if amount_type and amount are defined, give them priority.
        if ($pp->{amount} and $pp->{amount_type}) {
            if ($pp->{amount_type} eq 'payout') {
                $pp->{payout} = $pp->{amount};
            } elsif ($pp->{amount_type} eq 'stake') {
                $pp->{ask_price} = $pp->{amount};
            } else {
                $pp->{payout} = 0;    # if we don't know what it is, set payout to zero
            }
        }

        # if stake is defined, set it to ask_price.
        if ($pp->{stake}) {
            $pp->{ask_price} = $pp->{stake};
        }

        unless (defined $pp->{payout} or defined $pp->{ask_price}) {
            $pp->{payout} = 0;        # last safety net
        }

        if (defined $pp->{tick_expiry}) {
            $pp->{date_expiry} = $pp->{date_start}->plus_time_interval(2 * $pp->{tick_count});
        }

        if (defined $pp->{duration}) {
            if (my ($number_of_ticks) = $pp->{duration} =~ /(\d+)t$/) {
                $pp->{tick_expiry} = 1;
                $pp->{tick_count}  = $number_of_ticks;
                $pp->{date_expiry} = $pp->{date_start}->plus_time_interval(2 * $pp->{tick_count});
            } else {
                # The thinking here is that duration is only added on purpose, but
                # date_expiry might be hanging around from a poorly reused hashref.
                my $duration    = $pp->{duration};
                my $underlying  = $pp->{underlying};
                my $start_epoch = $pp->{date_start}->epoch;
                my $expiry;
                if ($duration =~ /d$/) {
                    # Since we return the day AFTER, we pass one day ahead of expiry.
                    my $expiry_date = Date::Utility->new($start_epoch)->plus_time_interval($duration);
                    # Daily bet expires at the end of day, so here you go
                    if (my $closing = $underlying->calendar->closing_on($expiry_date)) {
                        $expiry = $closing->epoch;
                    } else {
                        $expiry = $expiry_date->epoch;
                        my $regular_day   = $underlying->calendar->regular_trading_day_after($expiry_date);
                        my $regular_close = $underlying->calendar->closing_on($regular_day);
                        $expiry = Date::Utility->new($expiry_date->date_yyyymmdd . ' ' . $regular_close->time_hhmmss)->epoch;
                    }
                } else {
                    $expiry = $start_epoch + Time::Duration::Concise->new(interval => $duration)->seconds;
                }
                $pp->{date_expiry} = Date::Utility->new($expiry);
            }
        }

        $pp->{date_start}  //= 1;    # Error conditions if it's not legacy or run, I guess.
        $pp->{date_expiry} //= 1;
    }

    return $pp;
}

sub _initialize_contract_config {
    my ($self, $c_type, $params) = @_;

    die 'contract type is required' unless $c_type;

    if (my $legacy_params = $self->_legacy_contract_types->{$c_type}) {
        $params->{$_} = $legacy_params->{$_} for keys %$legacy_params;
    }

    $params->{bet_type} = $c_type unless $params->{bet_type};

    if (not exists $contract_type_config->{$params->{bet_type}}) {
        $params->{bet_type} = 'INVALID';
    }

    my %c_type_config = %{$contract_type_config->{$params->{bet_type}}};

    $params->{$_} = $c_type_config{$_} for keys %c_type_config;

    return;
}

sub _initialize_barrier {
    my ($self, $barrier, $contract_params) = @_;

    # if it is a hash reference, we will treat it as a double barrier contract.
    if (ref $barrier eq 'HASH') {
        $contract_params->{supplied_high_barrier} = $barrier->{barrier};
        $contract_params->{supplied_low_barrier}  = $barrier->{barrier2};
    } else {
        $contract_params->{supplied_barrier} = $barrier;
    }

    # just to make sure that we don't accidentally pass in undef barriers
    delete $contract_params->{$_} for qw(barrier high_barrier low_barrier);

    return;
}

has _legacy_contract_types => (
    is      => 'ro',
    default => sub {
        {
            INTRADU => {
                bet_type                   => 'CALL',
                is_forward_starting        => 1,
                starts_as_forward_starting => 1
            },
            INTRADD => {
                bet_type                   => 'PUT',
                is_forward_starting        => 1,
                starts_as_forward_starting => 1
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
        };
    },
);

has is_quanto => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_is_quanto {
    my $self = shift;

    my $pp         = $self->parameters;
    my $underlying = $pp->{underlying};

    # Everything should have a quoted currency, except our randoms.
    # However, rather than check for random directly, just do a numeraire bet if we don't know what it is.
    my $priced_with;
    if ($underlying->quoted_currency_symbol eq $pp->{currency} or (none { $underlying->market->name eq $_ } (qw(forex commodities indices)))) {
        $priced_with = 'numeraire';
    } elsif ($underlying->asset_symbol eq $pp->{currency}) {
        $priced_with = 'base';
    } else {
        $priced_with = 'quanto';
    }

    if ($underlying->submarket->name eq 'smart_fx') {
        $priced_with = 'numeraire';
    }

    return ($priced_with eq 'quanto');
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
