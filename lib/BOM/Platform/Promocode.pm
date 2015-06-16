package BOM::Platform::Promocode;

use strict;
use warnings;

use JSON qw(to_json);
use BOM::Database::DataMapper::Transaction;
use Try::Tiny;

sub process_promotional_code {
    my $client = shift;
    my $cpc    = $client->client_promo_code;
    my $pc     = $cpc->promotion;
    $pc->{_json} = {};
    try {
        $pc->{_json} = JSON::from_json($pc->promo_code_config);
    };

    # if promotion is expired..
    return if $pc->expiry_date && $pc->expiry_date < DateTime->now;

    # if a first deposit made but in a different currency..
    if (   $pc->{_json}{currency} ne 'ALL'
        && $pc->promo_code_type eq 'GET_X_WHEN_DEPOSIT_Y'
        && ($client->first_funded_amount || -1) > 0
        && $client->first_funded_currency ne $pc->{_json}{currency})
    {
        $client->promo_code_status('CANCEL');
        $client->save();
        return;
    }

    # if no bonus-triggering deposits yet..
    if ($pc->promo_code_type eq 'GET_X_WHEN_DEPOSIT_Y'
        && ($client->first_funded_amount || -1) <= 0)
    {
        return;
    }

    my $currency = $pc->{_json}{currency};
    $currency = $client->currency if $currency eq 'ALL';
    my $total_turnover = BOM::Database::DataMapper::Transaction->new({
            client_loginid => $client->loginid,
            currency_code  => $currency,
        })->get_turnover_of_account();

    # if free-bet min-turnover reached..
    if ($pc->promo_code_type eq 'FREE_BET') {
        if (my $min = $pc->{_json}{min_turnover}) {
            if ($total_turnover >= $min) {
                $client->promo_code_status('APPROVAL');
                $client->save();
            } else {
                # wait for more turnover
            }
        } else {
            $client->promo_code_status('APPROVAL');
            $client->save();
        }
        return;
    }

    # if get-x min deposit made and turnover target reached..
    if ($pc->promo_code_type eq 'GET_X_WHEN_DEPOSIT_Y') {
        if ($client->first_funded_amount >= $pc->{_json}{min_deposit}) {
            my $xy_turnover_limit = 5 * $pc->{_json}{amount};
            if ($total_turnover >= $xy_turnover_limit) {
                $client->promo_code_status('APPROVAL');
                $client->save();
            } else {
                # wait for more turnover
            }
        } else {
            $client->promo_code_status('CANCEL');
            $client->save();
        }
        return;
    }

    return;
}

1;
