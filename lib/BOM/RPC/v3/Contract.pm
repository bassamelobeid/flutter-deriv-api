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
use LandingCompany::Offerings;

use BOM::Platform::Chronicle;
use BOM::Platform::Config;
use BOM::RPC::v3::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Context qw (localize request);
use BOM::Platform::Locale;
use BOM::Platform::Runtime;

sub validate_symbol {
    my $symbol = shift;
    my @offerings =
        LandingCompany::Offerings->get('common', BOM::Platform::Runtime->instance->get_offerings_config)->values_for_key('underlying_symbol');
    if (!$symbol || none { $symbol eq $_ } @offerings) {

        # There's going to be a few symbols that are disabled or otherwise not provided
        # for valid reasons, but if we have nothing, or it's a symbol that's very
        # unlikely to be disabled, it'd be nice to know.
        warn "Symbol $symbol not found, our offerings are: " . join(',', @offerings)
            if $symbol and ($symbol =~ /^R_(100|75|50|25|10)$/ or not @offerings);

        return BOM::RPC::v3::Utility::create_error({
            code              => 'InvalidSymbol',
            message_to_client => localize("Symbol [_1] invalid.", $symbol),
        });
    }
    return;
}

sub validate_license {
    my $ul = shift;

    if ($ul->feed_license ne 'realtime') {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'NoRealtimeQuotes',
            message_to_client => localize("Realtime quotes not available for [_1].", $ul->symbol),
        });
    }

    return;
}

sub validate_is_open {
    my $ul = shift;

    unless (Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader())->is_open($ul->exchange)) {
        return BOM::RPC::v3::Utility::create_error({
            code              => 'MarketIsClosed',
            message_to_client => localize('This market is presently closed.'),
        });
    }

    return;
}

sub validate_underlying {
    my $symbol = shift;

    my $response = validate_symbol($symbol);
    return $response if $response;

    my $ul = create_underlying($symbol);

    $response = validate_license($ul);
    return $response if $response;

    $response = validate_is_open($ul);
    return $response if $response;

    return $ul;
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

=head2 longcode

Perform a longcode lookup - this is entirely handled by our
utility function of the same name in L<BOM::RPC::v3::Utility/longcode>.

=cut

sub longcode {
    my ($params) = @_;
    return BOM::RPC::v3::Utility::longcode($params);
}

1;
