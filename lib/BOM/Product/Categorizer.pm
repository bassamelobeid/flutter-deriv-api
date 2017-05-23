package BOM::Product::Categorizer;

use Moose;

=head1 NAME

BOM::Product::Categorizer

=head1 DESCRIPTION

A class to describe a contract based on the input parameters.

One of the optimizations that we want to do in pricing is to load market data prior to contract object creation.
To achieve that, we need to extract some contract information to determine which market data to load, hence this class was created.

But we are not there yet because there's a lot of refactoring needed to have the desired interface.

=cut

use Date::Utility;
use Quant::Framework;
use Finance::Contract::Category;

use BOM::Platform::Chronicle;
use BOM::MarketData qw(create_underlying);
use Finance::Contract::Category;

has parameters => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
);

sub BUILD {
    my $self = shift;

    my $c_types  = $self->contract_types;
    my $barriers = $self->barriers;

    my $barrier_type_count = grep { $_->{category}->two_barriers } @$c_types;

    if ($barrier_type_count > 0 and $barrier_type_count < scalar(@$c_types)) {
        die 'Could not mixed single barrier and double barrier contracts in bet_types list.';
    }

    # $barrier_type_count == 0, single barrier contract
    # $barrier_type_count == @$c_types, double barrier contract
    if ($barrier_type_count == 0 and grep { ref $_ } @$barriers) {
        die 'Invalid barrier list. Single barrier input is expected.';
    } elsif (
        $barrier_type_count == scalar(@$c_types) and grep {
            !ref $_
        } @$barriers
        )
    {
        die 'Invalid barrier list. Double barrier input is expected.';
    }

    return;
}

has [qw(contract_types barriers)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_contract_types {
    my $self = shift;

    my $p = $self->parameters;

    my $c_types;
    if ($p->{bet_types}) {
        $c_types = $p->{bet_types};
    } elsif ($p->{bet_type}) {
        $c_types = [$p->{bet_type}];
    } else {
        die 'bet_type is required';
    }

    return [map { $self->_initialize_contract_config($_) } @$c_types];
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
        if (@$barriers) {
            foreach my $barrier (@$barriers) {
                my $barrier_info = $self->_initialize_barrier($barrier);
                my $clone = {%$contract_params, %$c_type, %$barrier_info};
                # just to make sure nothing gets pass through
                delete $clone->{$_} for qw(bet_types barriers barrier high_barrier low_barrier);
                $clone->{build_parameters} = {%$clone};
                push @params, $clone;
            }
        } else {
            my $clone = {%$contract_params, %$c_type};
            # sometimes barriers could be undefined
            $clone->{build_parameters} = {%$clone};
            push @params, $clone;
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
    unless ($pp->{date_start}) {
        # An undefined or missing date_start implies that we want a bet which starts now.
        $pp->{date_start} = Date::Utility->new;
        # Force date_pricing to be similarly set, but make sure we know below that we did this, for speed reasons.
        $pp->{pricing_new} = 1;
    } else {
        $pp->{date_start} = Date::Utility->new($pp->{date_start});
    }

    if (defined $pp->{date_pricing}) {
        $pp->{date_pricing} = Date::Utility->new($pp->{date_pricing});
    }

    unless ($pp->{underlying}->isa('Quant::Framework::Underlying')) {
        $pp->{underlying} = create_underlying($pp->{underlying}, $pp->{date_pricing});
    }

    # If they gave us a date for start and pricing, then we need to do some magic.
    if ($pp->{date_pricing}) {
        if (not($pp->{underlying}->for_date and $pp->{underlying}->for_date->is_same_as($pp->{date_pricing}))) {
            $pp->{underlying} = create_underlying($pp->{underlying}->symbol, $pp->{date_pricing});
        }
    }

    my $for_date = $pp->{underlying}->for_date;
    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader($for_date), $for_date);

    if (defined $pp->{date_expiry}) {
        # to support legacy shortcode where expiry date is date string in dd-mmm-yy format
        if (Date::Utility::is_ddmmmyy($pp->{date_expiry})) {
            my $for_date    = $pp->{underlying}->for_date;
            my $exchange    = $pp->{underlying}->exchange;
            my $date_expiry = Date::Utility->new($pp->{date_expiry});
            if (my $closing = $trading_calendar->closing_on($exchange, $date_expiry)) {
                $pp->{date_expiry} = $closing;
            } else {
                my $regular_close = $trading_calendar->closing_on($exchange, $trading_calendar->regular_trading_day_after($exchange, $date_expiry));
                $pp->{date_expiry} = Date::Utility->new($date_expiry->date_yyyymmdd . ' ' . $regular_close->time_hhmmss);
            }
        } else {
            $pp->{date_expiry} = Date::Utility->new($pp->{date_expiry});
        }
    }

    $pp->{starts_as_forward_starting} //= 0;
    $pp->{landing_company}            //= 'costarica';

    # hash reference reusef
    delete $pp->{expiry_daily};
    delete $pp->{is_intraday};

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
       if (my ($number_of_tokens) = $pp->{duration} =~ /(\d+)c$/){
           $pp->{number_of_tokens} = $number_of_tokens;
 
       }elsif (my ($number_of_ticks) = $pp->{duration} =~ /(\d+)t$/) {
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
                if (my $closing = $trading_calendar->closing_on($underlying->exchange, $expiry_date)) {
                    $expiry = $closing->epoch;
                } else {
                    $expiry = $expiry_date->epoch;
                    my $regular_day = $trading_calendar->regular_trading_day_after($underlying->exchange, $expiry_date);
                    my $regular_close = $trading_calendar->closing_on($underlying->exchange, $regular_day);
                    $expiry = Date::Utility->new($expiry_date->date_yyyymmdd . ' ' . $regular_close->time_hhmmss)->epoch;
                }
            } else {
                $expiry = $start_epoch + Time::Duration::Concise->new(interval => $duration)->seconds;
            }
            $pp->{date_expiry} = Date::Utility->new($expiry);
        }
    }

    $pp->{date_start} //= 1;    # Error conditions if it's not legacy or run, I guess.

    return $pp;
}

sub _initialize_contract_config {
    my ($self, $c_type) = @_;

    die 'contract type is required' unless $c_type;

    my $contract_type_config = Finance::Contract::Category::get_all_contract_types();

    my $params;

    if (not exists $contract_type_config->{$c_type}) {
        $c_type = 'INVALID';
    }

    my %c_type_config = %{$contract_type_config->{$c_type}};

    $params->{$_} = $c_type_config{$_} for keys %c_type_config;
    $params->{bet_type} = $c_type;
    $params->{category} = Finance::Contract::Category->new($params->{category}) if $params->{category};

    return $params;
}

sub _initialize_barrier {
    my ($self, $barrier) = @_;

    my $barrier_info;
    # if it is a hash reference, we will treat it as a double barrier contract.
    if (ref $barrier eq 'HASH') {
        $barrier_info->{supplied_high_barrier} = $barrier->{barrier};
        $barrier_info->{supplied_low_barrier}  = $barrier->{barrier2};
    } else {
        $barrier_info->{supplied_barrier} = $barrier;
    }

    return $barrier_info;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
