#!perl

use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::Warnings qw(had_no_warnings);

use Format::Util::Numbers qw/formatnumber/;
use Date::Utility;
use Time::Duration::Concise;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Database::Model::OAuth;

use BOM::Test::RPC::Client;
use Test::BOM::RPC::Contract;

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $loginid = $client->loginid;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

$client->deposit_virtual_funds;
my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $params = {
    language            => 'EN',
    token               => $token,
    source              => 1,
    contract_parameters => {
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "duration"      => "5000000000000000",
        "duration_unit" => "d",
        "symbol"        => "R_50",
    },
};

subtest 'get proposal with invalid duration' => sub {
    my $ask_params = {
        client_ip => '127.0.0.1',
        args      => $params->{contract_parameters}};

    $c->call_ok('send_ask', $ask_params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure');
};

subtest 'buy with invalid duration' => sub {
    my (undef, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(client => $client);
    $params->{args}{price} = $txn_con->contract->ask_price;
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure');
};

subtest 'buy with invalid expiry date' => sub {
    delete $params->{contract_parameters}{duration};
    delete $params->{contract_parameters}{duration_unit};
    $params->{contract_parameters}{date_expiry} = Date::Utility->new->epoch + 9999999999;
    $c->call_ok('buy', $params)->has_no_system_error->has_error->error_code_is('InvalidtoBuy');
};

subtest 'get proposal with invalid expiry date' => sub {
    my $ask_params = {
        client_ip => '127.0.0.1',
        args      => $params->{contract_parameters}};

    $c->call_ok('send_ask', $ask_params)->has_no_system_error->has_error->error_code_is('OfferingsValidationError');
};

had_no_warnings();
done_testing();
