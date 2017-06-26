package BOM::RPC::v3::Contract;

use strict;
use warnings;
no indirect;

use Try::Tiny;
use List::MoreUtils qw(none);
use JSON::XS;
use Date::Utility;
use Time::HiRes;
use DataDog::DogStatsd::Helper qw(stats_timing stats_inc);

use Quant::Framework;
use LandingCompany::Offerings qw(get_offerings_with_filter);

use BOM::Platform::Chronicle;
use BOM::Platform::Config;
use BOM::RPC::v3::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Locale;
use BOM::Platform::Runtime;

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

    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader());
    my $u                = create_underlying($symbol);

    unless ($trading_calendar->is_open($u->exchange)) {
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
    } elsif ($p1->{contract_type} !~ /^(ASIAN|DIGITEVEN|DIGITODD)/) {
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
