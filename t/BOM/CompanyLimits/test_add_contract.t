#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 4;
use Test::Warnings;
use Test::Exception;
use JSON::MaybeXS;

use Date::Utility;
use BOM::Test;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Contract qw(create_contract buy_contract sell_contract);
use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
use BOM::Test::Email qw(mailbox_search);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

# Mocking currency conversion becomes needed because of the method close_all_open_contracts
# which sells all contracts in the unit test database. Because CompanyLimits converts all
# currencies to USD this method is called. This is a temporary change; we may replace the
# database implementation which the code in this file tests.
my $mocked_CurrencyConverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');

$mocked_CurrencyConverter->mock(
    'in_usd',
    sub {
        my $price         = shift;
        my $from_currency = shift;

        $from_currency eq 'AUD' and return 0.90 * $price;
        $from_currency eq 'BCH' and return 1200 * $price;
        $from_currency eq 'ETH' and return 500 * $price;
        $from_currency eq 'LTC' and return 120 * $price;
        $from_currency eq 'EUR' and return 1.18 * $price;
        $from_currency eq 'GBP' and return 1.3333 * $price;
        $from_currency eq 'JPY' and return 0.0089 * $price;
        $from_currency eq 'BTC' and return 5500 * $price;
        $from_currency eq 'USD' and return 1 * $price;
        return 0;
    });

my $redis = BOM::Config::RedisReplicated::redis_limits_write;
my $json  = JSON::MaybeXS->new;

# Test for the correct key combinations
#subtest 'Combinations matching test', sub {
#    my $cl = create_client;
#    top_up $cl, 'USD', 5000;
#
#};

# Test with different underlying

subtest 'Different landing companies test', sub {

    top_up my $cr_cl = create_client('CR'), 'USD', 5000;
    top_up my $mx_cl = create_client('MX'), 'USD', 5000;

    my ($error, $contract_info_svg, $contract_info_mx, $contract);

    $contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
    );

    ($error, $contract_info_svg) = buy_contract(
        client    => $cr_cl,
        buy_price => 2,
        contract  => $contract,
    );

    my $key = 'tn,R_50,callput';

    my $svg_total = $redis->hget('svg:potential_loss', $key);
    my $mx_total = $redis->hget('iom:potential_loss', $key) // 0;

    cmp_ok $svg_total, '==', 4, 'buying contract with CR client adds potential loss to svg';
    cmp_ok $mx_total,  '==', 0, 'buying contract with CR client does not affect mx potential_loss';

    ($error, $contract_info_mx) = buy_contract(
        client    => $mx_cl,
        buy_price => 2,
        contract  => $contract,
    );

    $svg_total = $redis->hget('svg:potential_loss', $key);
    $mx_total  = $redis->hget('iom:potential_loss', $key);

    cmp_ok $svg_total, '==', 4, 'buying contract with MX client does not add potential loss to svg';
    cmp_ok $mx_total,  '==', 4, 'buying contract with MX client affects mx potential_loss';

    $redis->hdel('svg:potential_loss', $key);
    $redis->hdel('iom:potential_loss', $key);
};

# Test with different barrier

# Test with different currencies
subtest 'Different currencies', sub {
    top_up my $cr_usd = create_client('CR'), 'USD', 5000;
    top_up my $cr_eur = create_client('CR'), 'EUR', 5000;

    my ($error, $contract_info_usd, $contract_info_eur, $usd_contract, $eur_contract);
    my $key = 'tn,R_50,callput';

    $usd_contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
        currency   => 'USD'
    );

    $eur_contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
        currency   => 'EUR'
    );

    ($error, $contract_info_usd) = buy_contract(
        client    => $cr_usd,
        buy_price => 2,
        contract  => $usd_contract,
    );

    my $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 4, 'buying contract with CR (USD) client adds potential loss to svg';

    ($error, $contract_info_eur) = buy_contract(
        client    => $cr_eur,
        buy_price => 2,
        contract  => $eur_contract,
    );

    $total = $redis->hget('svg:potential_loss', $key);

    cmp_ok $total, '>=', 8, 'buying contract with CR (EUR) client adds potential loss to svg';

    my $fmb = $contract_info_usd->{fmb};

    sell_contract(
        client       => $cr_usd,
        contract_id  => $fmb->{id},
        contract     => $usd_contract,
        sell_outcome => 1,
    );

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 4.72, 'selling contract with win (CR - USD) deducts potential loss to svg';

    $fmb = $contract_info_eur->{fmb};

    sell_contract(
        client       => $cr_eur,
        contract_id  => $fmb->{id},
        contract     => $eur_contract,
        sell_outcome => 0,
    );

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 0, 'selling contract with loss (CR - EUR) reduces potential loss to 0';

    $redis->hdel('svg:potential_loss', $key);
};

# Test with different contract groups

# Test with daily loss and daily turnover

# Test when limits have breached

# Test if database and redis are synced properly

# Test for potential loss reconciliation

subtest 'Limits test base case', sub {
    my $cl = create_client;
    top_up $cl, 'USD', 5000;

    my ($contract, $error, $contract_info, $total);

    $contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
    );

    ($error, $contract_info) = buy_contract(
        client    => $cl,
        buy_price => 2,
        contract  => $contract,
    );

    my $key = 'tn,R_50,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 4, 'buying contract adds correct potential loss';

    my $fmb = $contract_info->{fmb};

    sell_contract(
        client       => $cl,
        contract_id  => $fmb->{id},
        contract     => $contract,
        sell_outcome => 1,
    );

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 0, 'selling contract with win, deducts potential loss from before';

    $contract = create_contract(
        payout     => 600,
        underlying => 'R_50',
    );

    $error = buy_contract(
        client    => $cl,
        buy_price => 200,
        contract  => $contract,
    );

};

