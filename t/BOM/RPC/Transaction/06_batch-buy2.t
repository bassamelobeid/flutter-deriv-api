#!perl

use strict;
use warnings;

use utf8;
use BOM::Test::RPC::Client;
use Test::More;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Test::BOM::RPC::Contract;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
my $loginid = $client->loginid;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$client->deposit_virtual_funds;
my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

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

subtest 'buy' => sub {
    my (undef, $txn) = Test::BOM::RPC::Contract::prepare_contract(client => $client);

    my $result = $c->call_ok(
        'buy_contract_for_multiple_accounts',
        {
            language            => 'EN',
            token               => $token,
            source              => 1,
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
                price  => $txn->contract->ask_price,
                tokens => ['DUMMY1', 'DUMMY2'],
            },
        })->has_no_system_error->has_no_error->result;
    # note explain $result;
    $result = $result->{result};
    is_deeply $result,
        [{
            token             => 'DUMMY1',
            code              => 'InvalidToken',
            message_to_client => 'Invalid token',
        },
        {
            token             => 'DUMMY2',
            code              => 'InvalidToken',
            message_to_client => 'Invalid token',
        },
        ],
        'got expected result';
};

done_testing();
