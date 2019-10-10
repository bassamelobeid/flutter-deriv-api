#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw(:all);
use Test::MockModule;
use Test::More tests => 3;
use Test::Warnings;
use Test::Exception;
use JSON::MaybeXS;

use Date::Utility;
use Data::Dumper;
use BOM::Test;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Contract qw(create_contract buy_contract sell_contract batch_buy_contract sell_by_shortcode);
use BOM::Test::ContractTestHelper qw(close_all_open_contracts reset_all_loss_hashes);
use BOM::Transaction::Limits::SyncLoss;
use BOM::Config::RedisTransactionLimits;
use BOM::Config::Runtime;
use BOM::Test::Email qw(mailbox_search);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

local $ENV{COMPANY_LIMITS_ENABLED} = 1;

my $redis = BOM::Config::RedisTransactionLimits::redis_limits_write;
my $json  = JSON::MaybeXS->new;

# Discard unit test bets as it affects limits redis sync with db
close_all_open_contracts();
reset_all_loss_hashes();

# Setup groups:
BOM::Transaction::Limits::Groups::_clear_cached_groups();
$redis->del('groups:contract', 'groups:underlying');
$redis->hmset('groups:contract',   'CALL', 'callput');
$redis->hmset('groups:underlying', 'R_50', 'volidx');

subtest 'Batch buy sell', sub {
    my $manager_client;
    my @client_list = map { create_client('CR', undef, {binary_user_id => $_}) } (1 .. 4);
    top_up($_, 'USD', 1000) foreach (@client_list);
    # Set manager_client as binary_user_id = 1
    ($manager_client, @client_list) = @client_list;

    my ($svg_contract, $error, $multiple, $svg_fmb, $mx_contract, $mx_trx, $mx_fmb);

    $svg_contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S0P'
    );

    ($error, $multiple) = batch_buy_contract(
        manager_client => $manager_client,
        clients        => \@client_list,
        contract       => $svg_contract,
        buy_price      => 2,
    );

    is $error, undef, 'no errors during batch buy';
    cmp_ok $redis->hget('svg:potential_loss', '++,R_50,+,+'), '==', 12,
        'Batch buy 3 contracts of potential loss 4 each, global potential loss for symbol should be 4 * 3 = 12';
    foreach my $b_id (2 .. 4) {
        cmp_ok $redis->hget('svg:potential_loss', "+,+,$b_id"),      '==', 4, "binary_user_id $b_id should have correct potential loss";
        cmp_ok $redis->hget('svg:turnover',       "+,R_50,+,$b_id"), '==', 2, "binary_user_id $b_id have correct turnover";
    }

    ($error, $multiple) = sell_by_shortcode(
        manager_client => $manager_client,
        clients        => \@client_list,
        shortcode      => $svg_contract->shortcode,
        sell_outcome   => 0.5,                        # Premature sell! Only win 50% of payout (3)
    );

    cmp_ok $redis->hget('svg:potential_loss', '++,R_50,+,+'), '==', 0, 'On sell, potential loss should be reverted';
    foreach my $b_id (2 .. 4) {
        cmp_ok $redis->hget('svg:potential_loss', "+,+,$b_id"),      '==', 0, "binary_user_id $b_id potential loss reverted";
        cmp_ok $redis->hget('svg:turnover',       "+,R_50,+,$b_id"), '==', 2, "binary_user_id $b_id should have same turnover as before after sell";
    }

    is $error, undef, 'Premature sell of 50% succeeded with no errors';
    cmp_ok $redis->hget('svg:realized_loss', '++,R_50,+,+'), '==', 3,
        'Batch sell 3 contracts of realized loss 2 each, global realized loss for symbol is correct ((sell_price - buy_price) * 3 = (3 - 2) * 3 = 3)';
    foreach my $b_id (2 .. 4) {
        cmp_ok $redis->hget('svg:realized_loss', "+,+,$b_id"), '==', 1, "binary_user_id $b_id should have correct realized_loss";
    }
};

subtest 'Batch buy on error must revert', sub {
    my $manager_client;
    my @client_list = map { create_client('CR', undef, {binary_user_id => $_}) } (5 .. 8);

    my $b_id7 = $client_list[2];
    # For binary_user_id 2 and 4, give only 3 USD, so second buy of contract
    # will throw insufficient balance error
    top_up($_, 'USD', 4) foreach (@client_list);
    top_up($b_id7, 'USD', 3);

    # Set manager_client as binary_user_id = 1
    ($manager_client, @client_list) = @client_list;

    my ($svg_contract, $error, $multiple, $svg_fmb, $mx_contract, $mx_trx, $mx_fmb);

    $svg_contract = create_contract(
        payout     => 10,
        underlying => 'R_50',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S0P'
    );

    ($error, $multiple) = batch_buy_contract(
        manager_client => $manager_client,
        clients        => \@client_list,
        contract       => $svg_contract,
        buy_price      => 3,
    );

    is $error, undef, 'no errors during batch buy';
    cmp_ok $redis->hget('svg:potential_loss', '++,R_50,+,+'), '==', 21,
        'Batch buy 3 contracts of potential loss 7 each, global potential loss for symbol should be 7 * 3 = 21';
    foreach my $b_id (6 .. 8) {
        cmp_ok $redis->hget('svg:potential_loss', "+,+,$b_id"),      '==', 7, "binary_user_id $b_id should have correct potential loss";
        cmp_ok $redis->hget('svg:turnover',       "+,R_50,+,$b_id"), '==', 3, "binary_user_id $b_id have correct turnover";
    }

    ($error, $multiple) = batch_buy_contract(
        manager_client => $manager_client,
        clients        => \@client_list,
        contract       => $svg_contract,
        buy_price      => 3,
    );

    is $error, undef, 'no errors during batch buy';
    is scalar(grep { defined $_->{error} } @$multiple), 2, 'There should be 2 failed buys';

    cmp_ok $redis->hget('svg:potential_loss', '++,R_50,+,+'), '==', 28,
        'Batch buy 3 same contracts again, but now only one passes. Should only increment by 7.';
    foreach my $b_id (6, 8) {
        cmp_ok $redis->hget('svg:potential_loss', "+,+,$b_id"),      '==', 7, "binary_user_id $b_id should have the same potential loss";
        cmp_ok $redis->hget('svg:turnover',       "+,R_50,+,$b_id"), '==', 3, "binary_user_id $b_id should have the same turnover";
    }

    cmp_ok $redis->hget('svg:potential_loss', "+,+,7"),      '==', 14, "binary_user_id 7 potential loss should increase by 7";
    cmp_ok $redis->hget('svg:turnover',       "+,R_50,+,7"), '==', 6,  "binary_user_id 7 should increase by 3";
};
