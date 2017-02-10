#!perl

use Test::Most;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Database::Model::OAuth;
use BOM::System::RedisReplicated;
use BOM::Platform::Runtime;
use BOM::MarketData qw(create_underlying);
initialize_realtime_ticks_db();
my $t = build_wsapi_test();

my $now = Date::Utility->new;
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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw(USD JPY JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    quote      => 100,
    epoch      => $now->epoch - 1,
    underlying => 'frxUSDJPY',
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    quote      => 101,
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    quote      => 102,
    epoch      => $now->epoch + 1,
    underlying => 'frxUSDJPY',
});

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->set_status('tnc_approval', 'system', BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version);
$client->save;

my $loginid = $client->loginid;
my $user    = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

$client->set_default_account('USD');
$client->smart_payment(
    currency     => 'USD',
    amount       => +300000,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);

my $underlying = create_underlying('frxUSDJPY');

SKIP: {
    skip 'Forex test does not work on the weekends.', 1 if not $underlying->calendar->is_open_at(Date::Utility->new);
    subtest 'buy forex trades with payout!' => sub {

        my %contract = (
            "amount"        => "100",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "symbol"        => "frxUSDJPY",
            "duration"      => "7",
            "duration_unit" => "d",
        );

        $t = $t->send_ok({
                json => {
                    "proposal" => 1,
                    %contract
                }});
        $t->message_ok;
        my $proposal_1  = decode_json($t->message->[1]);
        my $proposal_id = $proposal_1->{proposal}->{id};
        my $buy_price   = $proposal_1->{proposal}->{ask_price};
        $t = $t->send_ok({
                json => {
                    buy   => $proposal_id,
                    price => $buy_price,
                }});

        $t->message_ok;
        my $res = decode_json($t->message->[1]);
        is $res->{buy}->{payout}, 100, 'Buy contract with proposal id : The payout is matching with defined amount 100';
        ok $res->{buy}->{buy_price} < 100, 'Buy contract with proposal id : Buy price is less than payout';

        $t = $t->send_ok({
                json => {
                    "proposal" => 1,
                    %contract
                }});
        $t->message_ok;
        $proposal_1  = decode_json($t->message->[1]);
        $proposal_id = $proposal_1->{proposal}->{id};

        $t = $t->send_ok({
                json => {
                    buy   => $proposal_id,
                    price => 10000,
                },
            });
        $t->message_ok;
        $res = decode_json($t->message->[1]);
        is $res->{buy}->{payout}, 100, 'Buy contract with proposal id : The payout is matching with defined amount 100';
        ok $res->{buy}->{buy_price} < 10000, 'Buy contract with defined proposal id : Exceucted at better price. Buy price is less than 10000';

        $t = $t->send_ok({
                json => {
                    "proposal" => 1,
                    %contract
                }});
        $t->message_ok;
        $proposal_1  = decode_json($t->message->[1]);
        $proposal_id = $proposal_1->{proposal}->{id};

        $t = $t->send_ok({
                json => {
                    buy   => $proposal_id,
                    price => 1,
                },
            });
        $t->message_ok;
        $res = decode_json($t->message->[1]);
        like(
            $res->{error}{message},
            qr/The underlying market has moved too much since you priced the contract. The contract price has changed/,
            'Buy contract with proposal id: price moved error'
        );

        # Buy with defined contract parameters
        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => $buy_price,
                    parameters => {%contract},
                }});

        $t->message_ok;
        $res = decode_json($t->message->[1]);
        is $res->{buy}->{payout}, 100, 'Buy contract with defined contract parameters : The payout is matching with defined amount 100';
        ok $res->{buy}->{buy_price} < 1000, 'Buy contract with defined contract parameters : Buy price is less than payout';

        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => 0,
                    parameters => {%contract},
                }});

        $t->message_ok;
        $res = decode_json($t->message->[1]);
        like(
            $res->{error}{message},
            qr/The underlying market has moved too much since you priced the contract. The contract price has changed/,
            'Buy contract with proposal id: price moved error'
        );

        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => $buy_price * 0.8,
                    parameters => {%contract},
                }});

        $t->message_ok;
        $res = decode_json($t->message->[1]);
        like(
            $res->{error}{message},
            qr/The underlying market has moved too much since you priced the contract. The contract price has changed/,
            'Buy contract with proposal id: price moved error'
        );

        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => $buy_price * 1.1,
                    parameters => {%contract},
                }});

        $t->message_ok;
        $res = decode_json($t->message->[1]);
        is $res->{buy}->{payout}, 100, 'Buy contract with defined contract parameters : The payout is matching with defined amount 100';
        ok $res->{buy}->{buy_price} < $buy_price * 1.1, 'Buy contract with defined contract parameters : Buy price at better price';

        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => 10000,
                    parameters => {%contract},
                },
            });
        $t->message_ok;
        $res = decode_json($t->message->[1]);
        is $res->{buy}->{payout}, 100, 'Buy contract with defined contract parameters : The payout is matching with defined amount 100';
        ok $res->{buy}->{buy_price} < 100, 'Buy contract with defined contract parameters : Exceucted at better price. Buy price is less than 100';

        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => 1,
                    parameters => {%contract},
                },
            });
        $t->message_ok;
        $res = decode_json($t->message->[1]);
        like(
            $res->{error}{message},
            qr/The underlying market has moved too much since you priced the contract. The contract price has changed/,
            'Buy contract with defined contract parameters: price moved error'
        );

    };
    subtest 'buy forex trades with stake!' => sub {

        my %contract = (
            "amount"        => "100",
            "basis"         => "stake",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "symbol"        => "frxUSDJPY",
            "duration"      => "7",
            "duration_unit" => "d",
        );

        $t = $t->send_ok({
                json => {
                    "proposal" => 1,
                    %contract
                }});
        $t->message_ok;
        my $proposal_1  = decode_json($t->message->[1]);
        my $proposal_id = $proposal_1->{proposal}->{id};
        my $buy_price   = $proposal_1->{proposal}->{ask_price};
        $t = $t->send_ok({
                json => {
                    buy   => $proposal_id,
                    price => $buy_price,
                }});

        $t->message_ok;
        my $res = decode_json($t->message->[1]);
        is $res->{buy}->{buy_price}, 100, 'Buy with proposal id: Buy price is matching 100';
        ok $res->{buy}->{payout} > 100, 'Buy with proposal id: Payout is greater than 100';
        $t = $t->send_ok({
                json => {
                    "proposal" => 1,
                    %contract
                }});
        $t->message_ok;
        $proposal_1  = decode_json($t->message->[1]);
        $proposal_id = $proposal_1->{proposal}->{id};

        $t = $t->send_ok({
                json => {
                    buy   => $proposal_id,
                    price => 10000,
                }});

        $t->message_ok;
        $res = decode_json($t->message->[1]);
        is $res->{buy}->{buy_price}, 100, 'Buy with proposal id: Buy price is 100';
        ok $res->{buy}->{payout} > 100, 'Buy with proposal id: Payout is greater than 100';
        $t = $t->send_ok({
                json => {
                    "proposal" => 1,
                    %contract
                }});
        $t->message_ok;
        $proposal_1  = decode_json($t->message->[1]);
        $proposal_id = $proposal_1->{proposal}->{id};

        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => 1,
                    parameters => {%contract},
                },
            });
        $t->message_ok;
        $res = decode_json($t->message->[1]);
        like(
            $res->{error}{message},
            qr/Contract's stake amount is more than the maximum purchase price/,
            'Buy with proposal id: Stake amount is more than purchase price'
        );

        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => $buy_price,
                    parameters => {%contract},
                },
            });
        $t->message_ok;
        $res = decode_json($t->message->[1]);
        is $res->{buy}->{buy_price}, 100, 'Buy with defined contract parameters: Buy price is 100';
        ok $res->{buy}->{payout} > 100, 'Buy with defined contract parameters: Payout is greater than 100';
        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => 10000,
                    parameters => {%contract},
                },
            });
        $t->message_ok;
        $res = decode_json($t->message->[1]);
        is $res->{buy}->{buy_price}, 100, 'Buy with defined contract parameters: Buy price is 100';
        ok $res->{buy}->{payout} > 100, 'Buy with defined contract parameters: Payout is greater than 100';

        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => 1,
                    parameters => {%contract},
                },
            });
        $t->message_ok;
        $res = decode_json($t->message->[1]);
        like(
            $res->{error}{message},
            qr/Contract's stake amount is more than the maximum purchase price/,
            'Buy with defined contract parameters: Stake amount is more than purchase price'
        );
        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => 0,
                    parameters => {%contract},
                }});

        $t->message_ok;
        $res = decode_json($t->message->[1]);
        like(
            $res->{error}{message},
            qr/The underlying market has moved too much since you priced the contract. The contract price has changed/,
            'Buy contract with proposal id: price moved error'
        );

        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => $buy_price * 0.8,
                    parameters => {%contract},
                }});

        $t->message_ok;
        $res = decode_json($t->message->[1]);
        like(
            $res->{error}{message},
            qr/The underlying market has moved too much since you priced the contract. The contract price has changed/,
            'Buy contract with proposal id: price moved error'
        );

        $t = $t->send_ok({
                json => {
                    buy        => 1,
                    price      => $buy_price * 1.1,
                    parameters => {%contract},
                }});

        $t->message_ok;
        $res = decode_json($t->message->[1]);
        is $res->{buy}->{payout}, 100, 'Buy contract with defined contract parameters : The payout is matching with defined amount 100';
        ok $res->{buy}->{buy_price} < $buy_price * 1.1, 'Buy contract with defined contract parameters : Buy price at better price';

        $t->finish_ok;
    };

}
done_testing();
