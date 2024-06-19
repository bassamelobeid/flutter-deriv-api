package BOM::Test::WebsocketAPI::Template::Proposal;

use strict;
use warnings;
no indirect;

my $json = JSON::MaybeXS->new->allow_blessed;

use BOM::Test::WebsocketAPI::Template::DSL;

request proposal => sub {
    my $contract = $_->contract;
    return proposal => {
        proposal      => 1,
        amount        => $contract->amount,
        basis         => $contract->basis,
        contract_type => $contract->contract_type,
        currency      => $contract->client->currency,
        symbol        => $contract->underlying->symbol,
        duration      => $contract->duration,
        duration_unit => $contract->duration_unit
    };
    },
    qw(contract);

rpc_request {
    my $contract = $_->contract;
    return {
        brand                      => 'binary',
        landing_company            => $contract->client->landing_company_name,
        app_markup_percentage      => '0',
        source                     => '1',
        source_bypass_verification => 0,
        logging                    => {},
        country_code               => 'aq',
        language                   => 'EN',
        valid_source               => '1',
        token                      => $contract->client->token,
        args                       => {
            proposal      => 1,
            product_type  => 'basic',
            contract_type => $contract->contract_type,
            symbol        => $contract->underlying->symbol,
            amount        => $contract->amount,
            basis         => $contract->basis,
            req_id        => 2,
            duration      => $contract->duration,
            duration_unit => $contract->duration_unit,
            currency      => $contract->client->currency
        }};
}
qw(contract);

rpc_response {
    my $contract = $_->contract;
    my $now_str  = '' . time;

    my $contract_parameters = {
        duration              => $contract->duration . $contract->duration_unit,
        product_type          => 'basic',
        base_commission       => '0.035',
        subscribe             => 1,
        proposal              => 1,
        date_start            => 0,
        app_markup_percentage => '0',
        underlying            => $contract->underlying->symbol,
        deep_otm_threshold    => '0.05',
        staking_limits        => {
            min => '0.5',
            max => 20000
        },
        amount      => $contract->amount,
        bet_type    => $contract->contract_type,
        amount_type => $contract->basis,
        currency    => $contract->client->currency,
        barrier     => $contract->barrier
    };

    my $subchannel   = _serialize_contract_parameters($contract_parameters);
    my $channel_args = {
        amount                 => 1000,
        basis                  => 'payout',
        contract_type          => $contract->contract_type,
        currency               => $contract->client->currency,
        duration               => $contract->duration,
        duration_unit          => $contract->duration_unit,
        landing_company        => $contract->client->landing_company_name,
        price_daemon_cmd       => "price",
        product_type           => 'basic',
        proposal               => 1,
        skips_price_validation => 1,
        symbol                 => $contract->underlying->symbol
    };

    $channel_args->{subscribe} = $_->{subscribe} if $_->{subscribe};

    my $channel              = _serialized_args($channel_args);
    my $subscription_channel = $channel . '::' . $subchannel;

    return {
        spot                 => $contract->entry_tick,
        spot_time            => $now_str,
        rpc_time             => '1023.498',
        display_value        => '10.00',
        ask_price            => '10.00',
        longcode             => $contract->longcode,
        payout               => $contract->payout_str,
        contract_parameters  => $contract_parameters,
        date_start           => $now_str,
        subchannel           => $subchannel,
        channel              => $channel,
        subscription_channel => $subscription_channel
    };
};

publish proposal => sub {
    my $contract = $_->contract;
    my $now_str  = '' . time;
    return {
        sprintf(
            'PRICER_ARGS::["amount","1000","basis","payout","contract_type","%s","currency","%s","duration","%s","duration_unit","%s","landing_company","%s","price_daemon_cmd","price","product_type","basic","proposal","1","skips_price_validation","1","subscribe","1","symbol","%s"]::v1,EUR,10,stake,0,0.05,0.035,,0.5,20000,,',
            $contract->contract_type, $contract->client->currency,             $contract->duration,
            $contract->duration_unit, $contract->client->landing_company_name, $contract->underlying->symbol
        ) => {
            ask_price        => '566.27',
            date_start       => $now_str,
            display_value    => '566.27',
            longcode         => $contract->longcode,
            payout           => '1000',
            price_daemon_cmd => 'price',
            rpc_time         => 51.094,
            spot             => '78.555',
            spot_time        => $now_str,
            theo_probability => 0.531265531071756,
        }};
};

1;

sub _serialized_args {
    my $copy = {%{+shift}};
    my $args = shift;
    my @arr  = ();

    delete $copy->{req_id};
    delete $copy->{language} unless $args->{keep_language};

    # We want to handle similar contracts together, so we do this and sort by
    # key in the price_queue.pl daemon
    push @arr, ('short_code', delete $copy->{short_code}) if exists $copy->{short_code};

    # Keep country only if it is CN.
    delete $copy->{country_code} if defined $copy->{country_code} and $copy->{country_code} ne 'cn';

    foreach my $k (sort keys %$copy) {
        push @arr, ($k, $copy->{$k});
    }

    return 'PRICER_ARGS::' . Encode::encode_utf8($json->encode([map { !defined($_) ? $_ : ref($_) ? $_ : "$_" } @arr]));
}

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
        $args->{multiplier}        // '',
    );
}
