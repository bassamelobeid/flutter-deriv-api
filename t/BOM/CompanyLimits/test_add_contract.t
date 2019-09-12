#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 3;
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

