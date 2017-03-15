package BOM::RPC::v3::Contract;

use strict;
use warnings;
no indirect;

use Try::Tiny;
use List::MoreUtils qw(none);
use JSON::XS;
use Date::Utility;

use BOM::Platform::Config;
use BOM::RPC::v3::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Locale;
use BOM::Platform::Runtime;
use LandingCompany::Offerings qw(get_offerings_with_filter);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );
use Format::Util::Numbers qw(roundnear);
use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);

use feature "state";

sub validate_symbol {
    my $symbol = shift;
    my @offerings = get_offerings_with_filter(BOM::Platform::Runtime->instance->get_offerings_config, 'underlying_symbol');
    if (!$symbol || none { $symbol eq $_ } @offerings) {

# There's going to be a few symbols that are disabled or otherwise not provided for valid reasons, but if we have nothing,
# or it's a symbol that's very unlikely to be disabled, it'd be nice to know.
        warn "Symbol $symbol not found, our offerings are: " . join(',', @offerings)
            if $symbol
            and ($symbol =~ /^R_(100|75|50|25|10)$/ or not @offerings);
        return {
            error => {
                code    => 'InvalidSymbol',
                message => "Symbol [_1] invalid",
                params  => [$symbol],
            }};
    }
    return;
}

sub validate_license {
    my $symbol = shift;
    my $u      = create_underlying($symbol);

    if ($u->feed_license ne 'realtime') {
        return {
            error => {
                code    => 'NoRealtimeQuotes',
                message => "Realtime quotes not available for [_1]",
                params  => [$symbol],
            }};
    }
    return;
}

sub validate_is_open {
    my $symbol = shift;
    my $u      = create_underlying($symbol);

    unless ($u->calendar->is_open) {
        return {
            error => {
                code    => 'MarketIsClosed',
                message => 'This market is presently closed.',
                params  => [$symbol],
            }};
    }
    return;
}

sub validate_underlying {
    my $symbol = shift;

    my $response = validate_symbol($symbol);
    return $response if $response;

    $response = validate_license($symbol);
    return $response if $response;

    $response = validate_is_open($symbol);
    return $response if $response;

    return {status => 1};
}


# pre-check
# this sub indicates error on RPC level if date_start or date_expiry of a new ask/contract are too far from now
sub pre_validate_start_expire_dates {
    my $params = shift;
    my ($start_epoch, $expiry_epoch, $duration);

    state $pre_limits_max_duration = 31536000;    # 365 days
    state $pre_limits_max_forward  = 604800;      # 7 days (Maximum offset from now for creating a contract)

    my $now_epoch = Date::Utility->new->epoch;

    # no try/catch here, expecting higher level try/catch
    $start_epoch =
        $params->{date_start}
        ? Date::Utility->new($params->{date_start})->epoch
        : $now_epoch;
    if ($params->{duration}) {
        if ($params->{duration} =~ /^(\d+)t$/) {    # ticks
            $duration = $1 * 2;
        } else {
            $duration = Time::Duration::Concise->new(interval => $params->{duration})->seconds;
        }
        $expiry_epoch = $start_epoch + $duration;
    } else {
        $expiry_epoch = Date::Utility->new($params->{date_expiry})->epoch;
        $duration     = $expiry_epoch - $start_epoch;
    }

    return
           if $start_epoch + 5 < $now_epoch
        or $start_epoch - $now_epoch > $pre_limits_max_forward
        or $duration > $pre_limits_max_duration;

    return 1;    # seems like ok, but everything will be fully checked later.
}

sub prepare_ask {
    my $p1 = shift;
    my %p2 = %$p1;

    $p2{date_start} //= 0;
    if ($p2{date_expiry}) {
        $p2{fixed_expiry} //= 1;
    }

    if (defined $p2{barrier} && defined $p2{barrier2}) {
        $p2{low_barrier}  = delete $p2{barrier2};
        $p2{high_barrier} = delete $p2{barrier};
    } elsif ($p1->{contract_type} !~ /^(SPREAD|ASIAN|DIGITEVEN|DIGITODD)/) {
        $p2{barrier} //= 'S0P';
        delete $p2{barrier2};
    }

    $p2{underlying}  = delete $p2{symbol};
    $p2{bet_type}    = delete $p2{contract_type};
    $p2{amount_type} = delete $p2{basis} if exists $p2{basis};
    if ($p2{duration} and not exists $p2{date_expiry}) {
        $p2{duration} .= (delete $p2{duration_unit} or "s");
    }

    return \%p2;
}
1;
