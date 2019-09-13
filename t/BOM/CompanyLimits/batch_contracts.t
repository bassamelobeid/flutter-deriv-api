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
use BOM::Test::Contract qw(create_contract buy_contract sell_contract batch_buy_contract);
use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
use BOM::Test::Email qw(mailbox_search);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $redis = BOM::Config::RedisReplicated::redis_limits_write;
my $json  = JSON::MaybeXS->new;

subtest 'Batch buy', sub {
    my $manager_client;
    my @client_list = map { create_client('CR', undef, {binary_user_id => $_}) } (1 .. 5);
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
        client_list    => \@client_list,
        contract       => $svg_contract,
        buy_price      => 2,
    );

    my $loss_hash = 'svg:potential_loss';
    cmp_ok $redis->hget($loss_hash, '++,R_50,+'), '==', 16,
        'Batch buy 4 contracts of potential loss 4 each, global potential loss for symbol should be 4 * 4 = 16';
    foreach my $b_id (2 .. 5) {
        cmp_ok $redis->hget($loss_hash, "+,+,$b_id"), '==', 4, "binary_user_id $b_id should have potential loss of 4";
    }
};

