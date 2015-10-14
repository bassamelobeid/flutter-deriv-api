package BOM::Platform::Account::Real::japan;

use strict;
use warnings;

use JSON qw(encode_json);
use BOM::Platform::Account::Real::default;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Platform::Email qw(send_email);

sub validate {
    my $args  = shift;
    my $check = BOM::Platform::Account::Real::default::validate($args);
    return $check if ($check->{err});

    #TODO: until we set JP <> restricted country
    return $check;
#    return $check if ($from_client->residence eq 'jp');

    return {err => 'Account opening unavailable'};
}

sub create_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Real::default::create_account({
        user    => $args->{user},
        details => $args->{details},
    });
    return $acc if ($acc->{err});

    my $client         = $acc->{client};
    my $financial_data = $args->{financial_data};

    $client->financial_assessment({
        data                        => encode_json($financial_data->{data}),
        total_score                 => $financial_data->{total_score},
        income_asset_score          => $financial_data->{total_score},
        trading_experience_score     => $financial_data->{total_score},
    });
    $client->set_status('unwelcome', 'SYSTEM', 'Trading disabled for investment Europe ltd');
    $client->save;

    if ($financial_evaluation->{total_score} > 59) {
        send_email({
            from    => request()->website->config->get('customer_support.email'),
            to      => BOM::Platform::Runtime->instance->app_config->compliance->email,
            subject => $client->loginid . ' considered as professional trader',
            message =>
                [$client->loginid . ' scored ' . $financial_evaluation->{total_score} . ' and is therefore considered a professional trader.'],
        });
    }
    return $acc;
}

1;
