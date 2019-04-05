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
use Email::Stuffer::TestLinks;

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

my $ask_params = {
    "proposal"      => 1,
    "amount"        => "100",
    "basis"         => "payout",
    "contract_type" => "CALL",
    "currency"      => "USD",
    "duration"      => 50000000000000,
    "duration_unit" => "d",
    "symbol"        => "R_50",
};

my $params_invalid_symbol = {
    language            => 'EN',
    token               => $token,
    source              => 1,
    contract_parameters => {
        "proposal"      => 1,
        "amount"        => "100",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "duration"      => "5",
        "duration_unit" => "",
        "symbol"        => "frxUS",
    },
};

my $buy_params = {
    args                => {price => 100},
    contract_parameters => {
        amount                => 100,
        app_markup_percentage => 1,
        basis                 => "stake",
        contract_type         => "CALL",
        currency              => "USD",
        duration              => 50000000000000,
        duration_unit         => "s",
        proposal              => 1,
        symbol                => "R_50"
    },
    language => "EN",
    source   => 1,
    token    => $token
};

subtest 'buy with invalid duration using contract_parameters' => sub {
    my (undef, $txn_con) = Test::BOM::RPC::Contract::prepare_contract(client => $client);
    $buy_params->{args}{price} = $txn_con->contract->ask_price;
    # use Data::Dumper::Concise;
    # my $cc =
    $c->call_ok('buy', $buy_params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code');
    # warn Dumper $cc->result;
};

subtest 'get proposal with invalid days duration' => sub {
    $c->call_ok('send_ask', {args => $ask_params})->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code');
};

subtest 'get proposal with invalid symbol' => sub {
    my $ask_params = {args => $params_invalid_symbol->{contract_parameters}};

    $c->call_ok('send_ask', $ask_params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code')
        ->error_message_is('Trading is not offered for this asset.', 'Trading is not offered for this asset.');
};

subtest 'buy with invalid days duration' => sub {
    $c->call_ok('buy', $buy_params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code');
};

$buy_params->{contract_parameters}{duration_unit} = 'h';
$ask_params->{duration_unit} = 'h';

subtest 'get proposal with invalid hours duration' => sub {
    $c->call_ok('send_ask', {args => $ask_params})->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code');
};

subtest 'buy with invalid hours duration' => sub {
    $c->call_ok('buy', $buy_params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code');
};

$buy_params->{contract_parameters}{duration_unit} = 'm';
$ask_params->{duration_unit} = 'm';

subtest 'get proposal with invalid minutes duration' => sub {
    $c->call_ok('send_ask', {args => $ask_params})->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code');
};

subtest 'buy with invalid minutes duration' => sub {
    $c->call_ok('buy', $buy_params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code');
};

$buy_params->{contract_parameters}{duration_unit} = 's';
$ask_params->{duration_unit} = 's';

subtest 'get proposal with invalid seconds duration' => sub {
    $c->call_ok('send_ask', {args => $ask_params})->has_no_system_error->has_error->error_code_is('ContractCreationFailure');
};

subtest 'buy with invalid seconds duration' => sub {
    $c->call_ok('buy', $buy_params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code');
};

$buy_params->{contract_parameters}{duration_unit} = 't';
$ask_params->{duration_unit} = 't';

subtest 'get proposal with invalid ticks duration' => sub {
    $c->call_ok('send_ask', {args => $ask_params})->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code');
};

subtest 'buy with invalid ticks duration' => sub {
    $c->call_ok('buy', $buy_params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code');
};

subtest 'buy with invalid expiry date' => sub {
    delete $buy_params->{contract_parameters}{duration};
    delete $buy_params->{contract_parameters}{duration_unit};
    $buy_params->{contract_parameters}{date_expiry} = Date::Utility->new->epoch + 9999999999;
    $c->call_ok('buy', $buy_params)->has_no_system_error->has_error->error_code_is('InvalidtoBuy', 'correct error code');
};

subtest 'get proposal with invalid expiry date' => sub {
    delete $ask_params->{duration};
    delete $ask_params->{duration_unit};
    $ask_params->{date_expiry} = Date::Utility->new->epoch + 9999999999;

    $c->call_ok('send_ask', {args => $ask_params})->has_no_system_error->has_error->error_code_is('OfferingsValidationError', 'correct error code');
};

subtest 'get digitmatch proposal with invalid input' => sub {
    $buy_params->{contract_parameters}{contract_type} = 'DIGITMATCH';
    $buy_params->{contract_parameters}{duration}      = '5';
    $buy_params->{contract_parameters}{duration_unit} = 't';
    $c->call_ok('buy', $buy_params)->has_no_system_error->has_error->error_code_is('ContractCreationFailure', 'correct error code')
        ->error_message_is(
        'Missing required contract parameters (last digit prediction for digit contracts).',
        'Missing required contract parameters (last digit prediction for digit contracts).'
        );
};

subtest 'get digitmatch proposal with invalid duration' => sub {
    $buy_params->{contract_parameters}{duration}      = '5';
    $buy_params->{contract_parameters}{duration_unit} = 'd';
    $buy_params->{contract_parameters}{barrier}       = '1';
    $c->call_ok('buy', $buy_params)->has_no_system_error->has_error->error_code_is('InvalidOfferings', 'correct error code')
        ->error_message_is('Trading is not offered for this duration.', 'Trading is not offered for this duration.');

};

had_no_warnings();
done_testing();
