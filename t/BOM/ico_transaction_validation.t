#!perl

use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

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
        symbol        => 'AS51',
        recorded_date => Date::Utility->new,
    });

my $now  = Date::Utility->new;
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'AS51',
});
my $currency   = 'USD';
my $underlying = create_underlying('AS51');

subtest 'validate client error message' => sub {

    my $bet_params = {
        bet_type   => 'BINARYICO',
        underlying => 'BINARYICO',
        stake      => '1.3501',
        currency   => 'USD',
        duration   => '1400c',
    };
    my $contract = produce_contract($bet_params);

    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $residence = $cr->residence;
    $cr->residence("");
    $cr->save();

    my $transaction = BOM::Transaction->new({
        client        => $cr,
        contract      => $contract,
        purchase_date => $now,
    });

    my $error = BOM::Transaction::Validation->new({
            clients     => [$cr],
            transaction => $transaction
        })->_is_valid_to_buy($cr);

    like($error->{-message_to_client}, qr/The ICO has not yet started./, 'The ICO has not yet started.');

    BOM::Platform::Runtime->instance->app_config->system->suspend->is_auction_started(1);

    $contract    = produce_contract($bet_params);
    $transaction = BOM::Transaction->new({
        client        => $cr,
        contract      => $contract,
        purchase_date => $now,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$cr],
            transaction => $transaction
        })->_validate_ico_jurisdictional_restrictions($cr);

    like(
        $error->{-message_to_client},
        qr/In order to participate in the ICO, we need to know your country of residence. Please update your account settings accordingly./,
        'No residence error'
    );

    $cr->residence('im');
    $cr->save;

    $contract    = produce_contract($bet_params);
    $transaction = BOM::Transaction->new({
        client        => $cr,
        contract      => $contract,
        purchase_date => $now,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$cr],
            transaction => $transaction
        })->_validate_ico_jurisdictional_restrictions($cr);

    like($error->{-message_to_client}, qr/Sorry, but the ICO is not available in your country of residence./, 'Not available for client residence');

    $cr->residence('gb');
    $cr->save;

    $contract    = produce_contract($bet_params);
    $transaction = BOM::Transaction->new({
        client        => $cr,
        contract      => $contract,
        purchase_date => $now,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$cr],
            transaction => $transaction
        })->_validate_ico_jurisdictional_restrictions($cr);

    like(
        $error->{-message_to_client},
        qr/The ICO is only available to professional investors in your country of residence. If you are a professional investor, please contact our customer support team to verify your account status./,
        'need to be professional'
    );

    $cr->set_status('professional');
    $cr->save;

    $contract    = produce_contract($bet_params);
    $transaction = BOM::Transaction->new({
        client        => $cr,
        contract      => $contract,
        purchase_date => $now,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$cr],
            transaction => $transaction
        })->_validate_ico_jurisdictional_restrictions($cr);

    is $error, undef, 'Validation successful';
};

done_testing;
