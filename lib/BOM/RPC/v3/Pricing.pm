package BOM::RPC::v3::Pricing;

use 5.014;
use strict;
use warnings;

use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::Utility;
use BOM::Platform::Context qw(localize);
use BOM::Pricing::v3::Contract;
use BOM::Pricing::v3::MarketData;
use BOM::Pricing::v3::Utility;
use Storable qw(dclone);

my $json = JSON::MaybeXS->new->allow_blessed;

rpc send_ask => sub {
    my ($params) = @_;

    $params->{landing_company} = $params->{landing_company} ? $params->{landing_company} : "virtual";

    # TODO: clean up send_ask so it does not change it's arguments.
    delete $params->{client};    # This field could be implicitly provided by `wrap_rpc_sub`, it is not used further,
                                 # but breaks `dclone` on the next line -- thus we delete it
    my $args = dclone $params;

    my $response = BOM::Pricing::v3::Contract::send_ask($params);
    if ($response->{error}) {
        $response->{error}{message_to_client} = localize($response->{error}{message_to_client});
    }

    if ($ENV{RECORD_PRICE_METRICS} and not exists $response->{error}) {
        my $relative_shortcode = BOM::Pricing::v3::Utility::create_relative_shortcode({$params->{args}->%*}, $response->{spot});
        BOM::Pricing::v3::Utility::update_price_metrics($relative_shortcode, $response->{rpc_time});
    }

    if (not $response->{skip_basis_override} and $args->{args}->{basis} and defined $args->{args}->{amount}) {
        $args->{args}->{amount} = 1000;
        $args->{args}->{basis}  = 'payout';
    }

    delete $response->{skip_basis_override};

    delete $args->{args}->{passthrough};

    $args->{args}->{language}         = $args->{language} || 'EN';
    $args->{args}->{price_daemon_cmd} = 'price';
    $args->{args}->{landing_company}  = $args->{landing_company};
    # use residence when available, fall back to IP country
    $args->{args}->{country_code}           = $args->{residence} || $args->{country_code};
    $args->{args}->{skips_price_validation} = 1;

    my $language = $args->{args}->{language};

    my $channel              = _serialized_args($args->{args});
    my $subchannel           = _serialize_contract_parameters($response->{contract_parameters}, $language);
    my $subscription_channel = $channel . '::' . $subchannel;

    my $market = BOM::RPC::v3::Utility::get_market_by_symbol($args->{args}->{symbol});

    $response->{longcode}             = localize($response->{longcode});
    $response->{channel}              = $channel;
    $response->{subchannel}           = $subchannel;
    $response->{subscription_channel} = $subscription_channel;
    $response->{stash}{market}        = $market;

    return $response;
};

rpc get_bid => sub {
    my $response = BOM::Pricing::v3::Contract::get_bid(@_);
    BOM::Pricing::v3::Utility::localize_bid_response($response);
    if ($response->{longcode}) {
        $response->{longcode} = localize($response->{longcode});
    }
    return $response;
};

rpc get_contract_details => sub {
    my $response = BOM::Pricing::v3::Contract::get_contract_details(@_);
    if ($response->{error}) {
        $response->{error}{message_to_client} = localize($response->{error}{message_to_client});
    } else {
        $response->{longcode} = localize($response->{longcode});
    }
    return $response;
};

rpc trading_times => \&BOM::Pricing::v3::MarketData::trading_times;

rpc asset_index => \&BOM::Pricing::v3::MarketData::asset_index;

rpc trading_durations => \&BOM::Pricing::v3::MarketData::trading_durations;

=head2 _serialized_args

Generation of proposal channel key

Encode the input in 'PRICER_ARGS::[hash_key_1 , hash_value_1, ... , hash_key_n, hash_value_n]' format sorted by hash key.

=cut

sub _serialized_args {
    my $copy = {%{+shift}};
    my @arr  = ();

    delete $copy->{req_id};
    delete $copy->{language};

    # We want to handle similar contracts together, so we do this and sort by
    # key in the price_queue.pl daemon
    push @arr, ('short_code', delete $copy->{short_code}) if exists $copy->{short_code};

    # TODO - replace hard coded value "CN" and "AQ"
    # Add "aq" country_code is temporary solution to unblock testing in Antartica region.
    # Proper solution will be designed and implemented under separate clickup tickets
    delete $copy->{country_code} if defined $copy->{country_code} and lc $copy->{country_code} ne 'cn' and lc $copy->{country_code} ne "aq";

    foreach my $k (sort keys %$copy) {
        push @arr, ($k, $copy->{$k});
    }

    return 'PRICER_ARGS::' . Encode::encode_utf8($json->encode([map { !defined($_) ? $_ : ref($_) ? $_ : "$_" } @arr]));
}

=head2 _serialize_contract_parameters

Generation of proposal subchannel key

Encode the input in 'v1,$currency,$amount,$amount_type, ... , $multiplier' format

=cut

sub _serialize_contract_parameters {
    my ($args, $language) = @_;

    my $staking_limits = $args->{staking_limits} // {};
    return join(
        ",",
        "v1",
        $args->{currency} // '',
        # binary
        $args->{amount}                // '',
        $args->{amount_type}           // '',
        $args->{app_markup_percentage} // '',
        $args->{deep_otm_threshold}    // '',
        $args->{base_commission}       // '',
        $args->{min_commission_amount} // '',
        $staking_limits->{min}         // '',
        $staking_limits->{max}         // '',
        # non-binary
        $args->{maximum_ask_price} // '',    # callputspread is the only contract type that has this
        $args->{multiplier}        // '',
        $language                  // '',
    );
}

1;
