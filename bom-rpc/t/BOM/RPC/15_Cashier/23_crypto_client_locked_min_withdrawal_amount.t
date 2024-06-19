use strict;
use warnings;
use Test::More;
use Test::Deep;
use BOM::RPC::v3::Utility;
use BOM::Config::Redis;

my $client_loginid  = 'CR1000';
my $client_currency = 'BTC';
my $currency_config = {currencies_config => {BTC => {minimum_withdrawal => 5}}};
subtest 'locked client minimum withdrawal amount' => sub {
    my $expected_minimum_withdrawal = 10;
    my $saved_min_amount            = BOM::RPC::v3::Utility::get_client_locked_min_withdrawal_amount($client_loginid);
    is undef, $saved_min_amount, 'returns undef when key not set';
    BOM::RPC::v3::Utility::set_client_locked_min_withdrawal_amount($client_loginid, $expected_minimum_withdrawal);
    $saved_min_amount = BOM::RPC::v3::Utility::get_client_locked_min_withdrawal_amount($client_loginid);
    is $expected_minimum_withdrawal, $saved_min_amount, 'correct amount fetched from redis';

    my $redis_write = BOM::Config::Redis::redis_replicated_write();
    $redis_write->del("rpc::cryptocurrency::crypto_config::client_min_amount::" . $client_loginid);
    my $expected_currency_config = $currency_config;
    BOM::RPC::v3::Utility::handle_client_locked_min_withdrawal_amount($currency_config, $client_loginid, $client_currency);
    cmp_deeply $expected_currency_config, $currency_config, 'same config as locked min withdrawal is not set';

    $expected_currency_config->{currencies_config}->{BTC}->{minimum_withdrawal} = $expected_minimum_withdrawal;
    BOM::RPC::v3::Utility::handle_client_locked_min_withdrawal_amount($currency_config, $client_loginid, $client_currency);
    cmp_deeply $expected_currency_config, $currency_config, 'updated config as locked min withdrawal is set';
};

done_testing;
