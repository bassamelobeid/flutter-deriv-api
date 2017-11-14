package BOM::RPC::v3::Static;

use strict;
use warnings;

use Format::Util::Numbers;
use List::Util qw( min );
use List::UtilsBy qw(nsort_by);
use Time::HiRes ();

use Brands;
use LandingCompany::Registry;
use Format::Util::Numbers qw/financialrounding/;
use Postgres::FeedDB::CurrencyConverter qw(in_USD amount_from_to_currency);
use DataDog::DogStatsd::Helper qw(stats_timing stats_gauge);

use BOM::Platform::Runtime;
use BOM::Platform::Locale;
use BOM::Platform::Config;
use BOM::Platform::Context qw (request);
use BOM::Database::ClientDB;
use BOM::RPC::v3::Utility;

# How wide each ICO histogram bucket is, in USD
use constant ICO_BUCKET_SIZE => 0.20;

sub residence_list {
    my $residence_countries_list;

    my $countries_instance = Brands->new(name => request()->brand)->countries_instance;
    my $countries = $countries_instance->countries;
    foreach my $country_selection (
        sort { $a->{translated_name} cmp $b->{translated_name} }
        map { +{code => $_, translated_name => $countries->localized_code2country($_, request()->language)} } $countries->all_country_codes
        )
    {
        my $country_code = $country_selection->{code};
        next if $country_code eq '';
        my $country_name = $country_selection->{translated_name};
        my $phone_idd    = $countries->idd_from_code($country_code);

        my $option = {
            value => $country_code,
            text  => $country_name,
            $phone_idd ? (phone_idd => $phone_idd) : ()};

        # to be removed later - JP
        if ($countries_instance->restricted_country($country_code) or $country_code eq 'jp') {
            $option->{disabled} = 'DISABLED';
        } elsif (request()->country_code eq $country_code) {
            $option->{selected} = 'selected';
        }
        push @$residence_countries_list, $option;
    }

    return $residence_countries_list;
}

sub states_list {
    my $params = shift;

    my $states = BOM::Platform::Locale::get_state_option($params->{args}->{states_list});
    $states = [grep { $_->{value} ne '' } @$states];
    return $states;
}

sub _currencies_config {
    my $amt_precision = Format::Util::Numbers::get_precision_config()->{price};
    my $bet_limits    = BOM::Platform::Config::quants->{bet_limits};
    # As a stake_default (amount, which will be pre-populated for this currency on our website,
    # if there were no amount entered by client), we get max out of two minimal possible stakes.
    # Logic is copied from _build_staking_limits

    # Get suspended currencies and remove them from list of legal currencies
    my @payout_currencies =
        BOM::RPC::v3::Utility::filter_out_suspended_cryptocurrencies(keys %{LandingCompany::Registry::get('costarica')->legal_allowed_currencies});

    my %currencies_config = map {
        $_ => {
            fractional_digits => $amt_precision->{$_},
            type              => LandingCompany::Registry::get_currency_type($_),
            stake_default     => min($bet_limits->{min_payout}->{volidx}->{$_}, $bet_limits->{min_payout}->{default}->{$_}) / 2,
            }
    } @payout_currencies;
    return \%currencies_config;
}

sub live_open_ico_bids {
    my ($currency) = @_;

    my $start = Time::HiRes::time();
    $currency //= 'USD';
    my $clientdb = BOM::Database::ClientDB->new({
        broker_code => 'CR',
        operation   => 'replica',
    });
    my $bids = $clientdb->db->dbh->selectall_arrayref(<<'SQL', {Slice => {}});
SELECT  acc.currency_code as "currency",
        qbv.binaryico_number_of_tokens as "tokens",
        qbv.binaryico_per_token_bid_price as "unit_price"
FROM    bet.financial_market_bet_open AS fmb
JOIN    transaction.account AS acc ON fmb.account_id = acc.id
JOIN    transaction.transaction AS txn ON fmb.id = txn.financial_market_bet_id
JOIN    data_collection.quants_bet_variables as qbv ON txn.id = qbv.transaction_id
WHERE   fmb.bet_class = 'coinauction_bet'
SQL

    # Divide these items into buckets - currently hardcoded at currency equivalent of 20c
    my %sum;
    my $bucket_size = ICO_BUCKET_SIZE;
    # Tiny adjustment to ensure bucket sizes are even
    my $epsilon   = 0.001;
    my $count     = 0;
    my $total_usd = 0;
    for my $bid (nsort_by { $_->{unit_price} } @$bids) {
        my $unit_price_usd = financialrounding(
            price => $currency,
            in_USD($bid->{unit_price}, $bid->{currency}));

        my $bucket = financialrounding(
            price => 'USD',
            $bucket_size * int(($epsilon + $unit_price_usd) / $bucket_size));
        $sum{$bucket} += $unit_price_usd * $bid->{tokens};
        $total_usd    += $unit_price_usd * $bid->{tokens};
        $count        += $bid->{tokens};
    }
    my $app_config      = BOM::Platform::Runtime->instance->app_config;
    my $minimum_bid_usd = financialrounding(
        price => 'USD',
        $app_config->system->suspend->ico_minimum_bid_in_usd
    );
    my $minimum_bid = financialrounding(
        price => $currency,
        amount_from_to_currency($minimum_bid_usd, USD => $currency));
    stats_gauge('binary.ico.bids.count',     $count);
    stats_gauge('binary.ico.bids.total_usd', $total_usd);
    my $elapsed = 1000.0 * (Time::HiRes::time() - $start);
    stats_timing('binary.ico.bids.calculation.elapsed', $elapsed);
    return {
        currency              => $currency,
        histogram_bucket_size => $bucket_size,
        minimum_bid           => $minimum_bid,
        minimum_bid_usd       => $minimum_bid_usd,
        histogram             => \%sum
    };
}

sub website_status {
    my $params = shift;

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    my $ico_info   = live_open_ico_bids('USD');
    $ico_info->{final_price} = $app_config->system->suspend->ico_final_price;

    return {
        terms_conditions_version => $app_config->cgi->terms_conditions_version,
        api_call_limits          => BOM::RPC::v3::Utility::site_limits,
        clients_country          => $params->{country_code},
        supported_languages      => $app_config->cgi->supported_languages,
        currencies_config        => _currencies_config(),
        ico_info                 => $ico_info,
        ico_status               => (
            $app_config->system->suspend->is_auction_ended
                or not $app_config->system->suspend->is_auction_started
        ) ? 'closed' : 'open',
    };
}

sub ico_status {
    my $params = shift;

    my $currency   = $params->{args}{currency} || 'USD';
    my $app_config = BOM::Platform::Runtime->instance->app_config;
    my $ico_info   = live_open_ico_bids($currency);
    $ico_info->{final_price_usd} = $app_config->system->suspend->ico_final_price;
    $ico_info->{final_price}     = amount_from_to_currency($ico_info->{final_price_usd}, USD => $currency);
    $ico_info->{ico_status}      = (
        $app_config->system->suspend->is_auction_ended
            or not $app_config->system->suspend->is_auction_started
    ) ? 'closed' : 'open';

    return $ico_info;
}

1;
