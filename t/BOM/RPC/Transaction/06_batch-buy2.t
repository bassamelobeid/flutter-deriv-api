#!perl

use strict;
use warnings;

use utf8;
use Test::BOM::RPC::Client;
use Test::More;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::Product;
use BOM::Database::Model::OAuth;

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $loginid = $client->loginid;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$client->deposit_virtual_funds;
my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
subtest 'buy' => sub {
    my $contract = BOM::Test::Data::Utility::Product::create_contract();

    my $result = $c->call_ok(
        'buy_contract_for_multiple_accounts',
        {
            language => 'EN',
            token    => $token,
            source   => 1,
            contract_parameters => {
                proposal      => 1,
                amount        => "100",
                basis         => "payout",
                contract_type => "CALL",
                currency      => "USD",
                duration      => "120",
                duration_unit => "s",
                symbol        => "R_50",
            },
            args => {
                price  => $contract->ask_price,
                tokens => ['DUMMY1', 'DUMMY2'],
            },
        })->has_no_system_error->has_no_error->result;
    # note explain $result;
    $result = $result->{result};
    is_deeply $result, [
        {
            token             => 'DUMMY1',
            code              => 'InvalidToken',
            message_to_client => 'Invalid token',
        },
        {
            token             => 'DUMMY2',
            code              => 'InvalidToken',
            message_to_client => 'Invalid token',
        },
    ], 'got expected result';
};

done_testing();
