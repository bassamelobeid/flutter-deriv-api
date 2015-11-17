package BOM::WebSocketAPI::v3::Cashier;

use strict;
use warnings;
use HTML::Entities;
use List::Util qw( min first );
use Format::Util::Numbers qw(to_monetary_number_format roundnear);
use BOM::Platform::Locale;
use BOM::Platform::Runtime;
use BOM::Utility::CurrencyConverter qw(amount_from_to_currency in_USD);
use BOM::Platform::Context qw(localize request);
use BOM::Database::DataMapper::PaymentAgent;

sub get_limits {
    my ($c, $args) = @_;

    my $r      = $c->stash('request');
    my $client = $c->stash('client');

    BOM::Platform::Context::request($c->stash('request'));

    # check if Client is not in lock cashier and not virtual account
    unless (not $client->get_status('cashier_locked') and not $client->documents_expired and $client->broker !~ /^VRT/) {
        return $c->new_error('get_limits', 'FeatureNotAvailable', localize('Sorry, this feature is not available.'));
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

sub paymentagent_list {
    my ($c, $args) = @_;

    my $r = $c->stash('request');

    my $payment_agent_mapper = BOM::Database::DataMapper::PaymentAgent->new({broker_code => ($r->loginid ? $r->broker->code : 'CR')});
    my $countries = $payment_agent_mapper->get_all_authenticated_payment_agent_countries();

    my $target_country = $args->{paymentagent_list};

    # add country name plus code
    foreach (@{$countries}) {
        $_->[1] = BOM::Platform::Runtime->instance->countries->localized_code2country($_->[0], $r->language);
    }

    my $payment_agent_table_row = __ListPaymentAgents($c, {target_country => $target_country});

    return {
        msg_type          => 'paymentagent_list',
        paymentagent_list => {
            available_countries => $countries,
            list                => $payment_agent_table_row
        },
    };
}

sub __ListPaymentAgents {
    my ($c, $args) = @_;

    my $r = $c->stash('request');

    my @allow_broker = map { $_->code } @{$r->website->broker_codes};

    my $payment_agent_mapper =
        BOM::Database::DataMapper::PaymentAgent->new({broker_code => (($r->loginid) ? $r->broker->code : 'CR')});
    my $authenticated_paymentagent_agents =
        $payment_agent_mapper->get_authenticated_payment_agents({target_country => $args->{target_country}});

    my %payment_agent_banks = %{BOM::Platform::Locale::get_payment_agent_banks()};

    my $payment_agent_table_row = [];
    foreach my $loginid (keys %{$authenticated_paymentagent_agents}) {
        my $payment_agent = $authenticated_paymentagent_agents->{$loginid};

        push @{$payment_agent_table_row},
            {
            'name'                  => encode_entities($payment_agent->{payment_agent_name}),
            'summary'               => encode_entities($payment_agent->{summary}),
            'url'                   => $payment_agent->{url},
            'email'                 => $payment_agent->{email},
            'telephone'             => $payment_agent->{phone},
            'currencies'            => $payment_agent->{currency_code},
            'deposit_commission'    => $payment_agent->{commission_deposit},
            'withdrawal_commission' => $payment_agent->{commission_withdrawal},
            'further_information'   => $payment_agent->{information},
            'supported_banks'       => $payment_agent->{supported_banks},
            };
    }

    @$payment_agent_table_row = sort { lc($a->{name}) cmp lc($b->{name}) } @$payment_agent_table_row;

    return $payment_agent_table_row;
}

1;
