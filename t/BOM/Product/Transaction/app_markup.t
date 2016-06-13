#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::MockModule;
use Crypt::NamedKeys;
use Date::Utility;

use BOM::Platform::Client;
use BOM::Platform::Client::Utility;
use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $requestmod = Test::MockModule->new('BOM::Platform::Context::Request');
$requestmod->mock('session_cookie', sub { return bless({token => 1}, 'BOM::Platform::SessionCookie'); });

initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD JPY JPY-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new,
    });

my $now  = Date::Utility->new;
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

sub create_client {
    my $broker = shift;
    $broker ||= 'CR';

    return BOM::Platform::Client->register_and_return_new_client({
        broker_code      => $broker,
        client_password  => BOM::System::Password::hashpw('12345678'),
        salutation       => 'Ms',
        last_name        => 'Doe',
        first_name       => 'Jane' . time . '.' . int(rand 1000000000),
        email            => 'jane.doe' . time . '.' . int(rand 1000000000) . '@test.domain.nowhere',
        residence        => 'in',
        address_line_1   => '298b md rd',
        address_line_2   => '',
        address_city     => 'Place',
        address_postcode => '65432',
        address_state    => 'st',
        phone            => '+9145257468',
        secret_question  => 'What the f***?',
        secret_answer    => BOM::Platform::Client::Utility::encrypt_secret_answer('is that'),
        date_of_birth    => '1945-08-06',
    });
}

subtest 'app_markup' => sub {
    my $client = create_client;

    my $loginid  = $client->loginid;
    my $currency = 'USD';

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $contract   = produce_contract({
        underlying   => $underlying,
        bet_type     => 'FLASHU',
        currency     => $currency,
        payout       => 10,
        duration     => '15m',
        current_tick => $tick,
        barrier      => 'S0P'
    });

    my $transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $contract
    });

    my $error = $transaction->buy;
    is $error, undef, 'no error';
};

done_testing();
