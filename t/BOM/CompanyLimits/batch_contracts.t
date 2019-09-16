#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use JSON::MaybeXS;

use Date::Utility;
use Data::Dumper;
use BOM::Test;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Contract qw(create_contract buy_contract sell_contract batch_buy_contract sell_by_shortcode);
use BOM::Test::ContractTestHelper qw(close_all_open_contracts);
use BOM::CompanyLimits::SyncLoss;
use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
use BOM::Test::Email qw(mailbox_search);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $redis = BOM::Config::RedisReplicated::redis_limits_write;
my $json  = JSON::MaybeXS->new;

# Discard unit test bets as it affects limits redis sync with db
close_all_open_contracts();
BOM::CompanyLimits::SyncLoss::reset_daily_loss_hashes(force_reset => 1);
$redis->del('svg:potential_loss');

subtest 'Batch buy', sub {
    my $manager_client;
    my @client_list = map { create_client('CR', undef, {binary_user_id => $_}) } (1 .. 4);
    top_up($_, 'USD', 1000) foreach (@client_list);
    # Set manager_client as binary_user_id = 1
    ($manager_client, @client_list) = @client_list;

    my ($svg_contract, $error, $multiple, $svg_fmb, $mx_contract, $mx_trx, $mx_fmb);

    $svg_contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
    );

    ($error, $multiple) = batch_buy_contract(
        manager_client => $manager_client,
        clients        => \@client_list,
        contract       => $svg_contract,
        buy_price      => 2,
    );

    is $error, undef, 'no errors during batch buy';
    my $loss_hash = 'svg:potential_loss';
    cmp_ok $redis->hget($loss_hash, '++,R_50,+'), '==', 12,
        'Batch buy 3 contracts of potential loss 4 each, global potential loss for symbol should be 4 * 3 = 12';
    foreach my $b_id (2 .. 4) {
        cmp_ok $redis->hget($loss_hash,     "+,+,$b_id"),      '==', 4, "binary_user_id $b_id should have correct potential loss";
        cmp_ok $redis->hget('svg:turnover', "+,R_50,+,$b_id"), '==', 2, "binary_user_id $b_id have correct turnover";
    }

    my %redis_result = @{$redis->hgetall('svg:potential_loss')};
    my $db_result    = BOM::CompanyLimits::SyncLoss::get_db_potential_loss('CR');
    $redis_result{$_} = $redis_result{$_} + 0 foreach (keys %redis_result);

    is_deeply \%redis_result, $db_result, 'Potential loss is same as database';

    is $redis->del('svg:potential_loss'), '1', 'Now delete potential loss hash table';
    %redis_result = @{$redis->hgetall('svg:potential_loss')};
    is_deeply \%redis_result, {}, 'Successfully deleted loss hash table';
    my $sync_response = BOM::CompanyLimits::SyncLoss::sync_potential_loss_to_redis('CR', 'svg');

    is $sync_response, 'OK', 'Sync from db to potential loss hash successful';
    %redis_result = @{$redis->hgetall('svg:potential_loss')};
    is_deeply \%redis_result, $db_result, 'Potential loss is still same as database after syncing with database (cause nothing changed)';

    ($error, $multiple) = sell_by_shortcode(
        manager_client => $manager_client,
        clients        => \@client_list,
        shortcode      => $svg_contract->shortcode,
        sell_outcome   => 0.5,                        # Premature sell! Only win 50% of payout (3)
    );

    is $error, undef, 'Premature sell of 50% succeeded with no errors';
    $loss_hash = 'svg:realized_loss';
    cmp_ok $redis->hget($loss_hash, '++,R_50,+'), '==', 3,
        'Batch sell 3 contracts of realized loss 2 each, global realized loss for symbol is correct ((sell_price - buy_price) * 3 = (3 - 2) * 3 = 3)';
    foreach my $b_id (2 .. 4) {
        cmp_ok $redis->hget($loss_hash, "+,+,$b_id"), '==', 1, "binary_user_id $b_id should have correct realized_loss";
    }
};

