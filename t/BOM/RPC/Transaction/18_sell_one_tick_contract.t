use strict;
use warnings;

use Test::MockTime::HiRes qw(set_absolute_time restore_time);
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::Database::Model::OAuth;
use BOM::MarketData qw(create_underlying);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Date::Utility;
use Postgres::FeedDB;
use BOM::Transaction;
use BOM::Test::Data::Utility::UnitTestMarketData;
use BOM::Test::RPC::QueueClient;

my $expected_result = {
    error => {
        message_to_client => 'The token is invalid.',
        code              => 'InvalidToken',
    },
    stash => {
        app_markup_percentage      => 0,
        valid_source               => 1,
        source_bypass_verification => 0
    },
};

my ($client, $client_token, $oauth_token);
my $rpc_ct;
my $method = 'sell_expired';

my @params = (
    $method,
    {
        language => 'EN',
        country  => 'ru',
        args     => {sell_expired => 1},
    });

subtest 'Initialization' => sub {
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $client->payment_free_gift(
            currency => 'USD',
            amount   => 10000,
            remark   => 'free gift',
        );

        my $m = BOM::Platform::Token::API->new;

        $client_token = $m->create_token($client->loginid, 'test token');

        ($params[1]->{token}) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
    }
    'Initial clients';

    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server';
};

subtest 'Sell one tick contract' => sub {
    my $underlying_symbol = 'R_50';
    my $is_expired        = 1;

    my $start_time = time;
    set_absolute_time($start_time);

    my $mock_du = Test::MockModule->new('Date::Utility');
    $mock_du->mock(
        'new',
        sub {
            # Sometimes `time` unsyncs from what's been set with `set_absolute_time`
            # Somewhat hackish, but it works!
            set_absolute_time($start_time) while ($start_time != time);
            return $mock_du->original('new')->(@_);
        });

    my $start = Date::Utility->new;

    initialize_realtime_ticks_db();
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD);
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'randomindex',
        {
            symbol => $underlying_symbol,
            date   => Date::Utility->new
        });

    my $dbic = Postgres::FeedDB::read_dbic;

    my @ticks;
    my @epoches = ($start->epoch, $start->epoch + 1);
    for my $epoch (@epoches) {
        my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(
            underlying => $underlying_symbol,
            dbic       => $dbic,
        );
        my $tick = $api->tick_at({end_time => $epoch});

        unless ($tick) {
            $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch      => $epoch,
                quote      => '963.3000',
                underlying => $underlying_symbol
            });
        }
        push @ticks, $tick;
    }
    my $underlying = create_underlying($underlying_symbol);

    my $contract_data = {
        underlying            => $underlying,
        bet_type              => 'DIGITEVEN',
        proposal              => 1,
        product_type          => 'basic',
        currency              => 'USD',
        app_markup_percentage => '0',
        date_start            => 0,
        amount                => 10,
        amount_type           => 'stake',
        duration              => '1t',
    };

    my $txn = BOM::Transaction->new({
        client              => $client,
        contract_parameters => $contract_data,
        purchase_date       => $start_time,
        amount_type         => 'stake',
    });
    $txn->buy;

    $rpc_ct->call_ok(@params)->result_is_deeply({
            count => 0,
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0
            }
        },
        'Should not be sold at the same second even future tick is exist'
    );

    $start_time += 1;
    set_absolute_time($start_time);

    $rpc_ct->call_ok(@params)->result_is_deeply({
            count => 1,
            stash => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0
            }
        },
        'Now its ready to be sold'
    );

    $mock_du->unmock_all;
    restore_time();
};

done_testing();
