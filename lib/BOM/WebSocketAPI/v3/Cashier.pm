package BOM::WebSocketAPI::v3::Cashier;

use strict;
use warnings;

use List::Util qw( min first );
use Format::Util::Numbers qw(to_monetary_number_format roundnear);
use BOM::Platform::Runtime;
use BOM::Utility::CurrencyConverter qw(amount_from_to_currency in_USD);

sub get_limits {
    my ($c, $args) = @_;

    my $r      = $c->stash('r');
    my $client = $c->stash('client');

    # check if Client is not in lock cashier and not virtual account
    unless (not $client->get_status('cashier_locked') and not $client->documents_expired and $client->broker !~ /^VRT/) {
        return $c->new_error('get_limits', 'FeatureNotAvailable', 'Sorry, this feature is not available.');
    }

    my $limit = +{
        map ({
                $_ => amount_from_to_currency($client->get_limit({'for' => $_}), 'USD', $client->currency);
            } (qw/account_balance daily_turnover payout/)),
        open_positions => $client->get_limit_for_open_positions,
    };

    my $landing_company = BOM::Platform::Runtime->instance->broker_codes->landing_company_for($client->broker)->short;
    my $wl_config       = $c->app_config->payments->withdrawal_limits->$landing_company;
    my $numdays         = $wl_config->for_days;
    my $numdayslimit    = $wl_config->limit_for_days;
    my $lifetimelimit   = $wl_config->lifetime_limit;

    if ($client->client_fully_authenticated) {
        $numdayslimit  = 99999999;
        $lifetimelimit = 99999999;
    }

    $limit->{num_of_days}       = $numdays;
    $limit->{num_of_days_limit} = $numdayslimit;
    $limit->{lifetime_limit}    = $lifetimelimit;

    if (not $client->client_fully_authenticated) {
        # withdrawal since $numdays
        my $payment_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $client->loginid});
        my $withdrawal_for_x_days = $payment_mapper->get_total_withdrawal({
            start_time => Date::Utility->new(Date::Utility->new->epoch - 86400 * $numdays),
            exclude    => ['currency_conversion_transfer'],
        });
        $withdrawal_for_x_days = roundnear(0.01, amount_from_to_currency($withdrawal_for_x_days, $client->currency, 'EUR'));

        # withdrawal since inception
        my $withdrawal_since_inception = $payment_mapper->get_total_withdrawal({exclude => ['currency_conversion_transfer']});
        $withdrawal_since_inception = roundnear(0.01, amount_from_to_currency($withdrawal_since_inception, $client->currency, 'EUR'));

        $limit->{withdrawal_since_inception_monetary} = to_monetary_number_format($withdrawal_since_inception, 1);
        $limit->{withdrawal_for_x_days_monetary}      = to_monetary_number_format($withdrawal_for_x_days,      $numdays);

        my $remainder = roundnear(0.01, min(($numdayslimit - $withdrawal_for_x_days), ($lifetimelimit - $withdrawal_since_inception)));
        if ($remainder < 0) {
            $remainder = 0;
        }

        $limit->{remainder} = $remainder;
    }

    return {
        msg_type   => 'get_limits',
        get_limits => $limit,
    };
}

1;
