package BOM::RPC::v3::Pricing;

use 5.014;
use strict;
use warnings;

use BOM::RPC::Registry '-dsl';

use BOM::Pricing::v3::Contract;
use BOM::Pricing::v3::MarketData;
use BOM::Pricing::v3::Utility;
use Storable qw(dclone);

my $json = JSON::MaybeXS->new->allow_blessed;

rpc send_ask => sub {
    my ($params) = @_;

    # TODO: clean up send_ask so it does not change it's arguments.
    my $args = dclone $params;

    my $response = BOM::Pricing::v3::Contract::send_ask($params);

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

    my $channel              = _serialized_args($args->{args});
    my $subchannel           = _serialize_contract_parameters($response->{contract_parameters});
    my $subscription_channel = $channel . '::' . $subchannel;

    $response->{channel}              = $channel;
    $response->{subchannel}           = $subchannel;
    $response->{subscription_channel} = $subscription_channel;

    return $response;
};

rpc get_bid => \&BOM::Pricing::v3::Contract::get_bid;

rpc get_contract_details => \&BOM::Pricing::v3::Contract::get_contract_details;

rpc contracts_for => \&BOM::Pricing::v3::Contract::contracts_for;

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

    # Keep country only if it is CN.
    delete $copy->{country_code} if defined $copy->{country_code} and lc $copy->{country_code} ne 'cn';

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
    my $args = shift;

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
        $args->{multiplier} // '',
    );
}

1;
