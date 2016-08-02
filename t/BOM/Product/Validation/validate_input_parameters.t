#!/etc/rmg/bin/perl

use Test::More;
use Test::FailWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Underlying;
use Date::Utility;

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestPrice;
use Test::MockModule;

my $now = Date::Utility->new('2016-03-18 01:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD', recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('index', {symbol => 'R_100', recorded_date => $now});

my $fake_tick = BOM::Market::Data::Tick->new({
    underlying => 'R_100',
    epoch => $now->epoch,
    quote => 100,
});

my $bet_params = {
    underlying   => 'R_100',
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 100,
    date_pricing => $now,
    barrier      => 'S0P',
    current_tick => $fake_tick,
};

subtest 'invalid start and expiry time' => sub {
    $bet_params->{date_start} = $bet_params->{date_expiry} = $now;
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/Start and Expiry times are the same/, 'expiry = start');
    $bet_params->{date_start} = $now;
    $bet_params->{date_expiry} = $now->epoch - 1;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/Start must be before expiry/, 'expiry < start');
    $bet_params->{date_start} = $now;
    $bet_params->{date_pricing} = $now->epoch + 1;
    $bet_params->{date_expiry} = $now->epoch + 20 *60;
    $bet_params->{entry_tick} = $fake_tick;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/starts in the past/, 'start < now');
    $bet_params->{for_sale} = 1;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy if it is a recreated contract';
    $bet_params->{date_start} = $now->epoch + 1;
    $bet_params->{date_pricing} = $now;
    $bet_params->{bet_type} = 'ONETOUCH';
    $bet_params->{barrier} = 110;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/Forward time for non-forward-starting contract type/, 'start > now for non forward starting contract type');
    $bet_params->{bet_type} = 'CALL';
    $bet_params->{barrier} = 'S0P';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for CALL at a forward start time';
    delete $bet_params->{for_sale};
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/forward-starting blackout/, 'forward starting blackout');
    $bet_params->{date_start} = $now->epoch + 5*60;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};

$fake_tick = BOM::Market::Data::Tick->new({
    underlying => 'frxUSDJPY',
    epoch => $now->epoch,
    quote => 100,
});

my $bet_params2 = {
    underlying   => 'frxUSDJPY',
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 100,
    date_start   => $now,
    date_pricing => $now,
    duration     => '4d',
    barrier      => '0',
    current_tick => $fake_tick,
};

subtest 'absolute barrier for a non-intraday contract' => sub {
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $now,
            rates => { 1 => 0, 100 => 0, 365 => 0 },
        }) for qw(USD JPY USD-JPY);

    my $forex = BOM::Market::Underlying->new('frxUSDJPY');

    my $delta_surface = Quant::Framework::VolSurface::Delta->new({
            deltas        => [75, 50, 25],
            underlying_config    => $forex->config,
            chronicle_reader =>  BOM::System::Chronicle::get_chronicle_reader,
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer,
            recorded_date => $now,
            surface       => {
                1 => {
                    smile => {
                        25 => 0.19,
                        50 => 0.15,
                        75 => 0.23,
                    },
                    vol_spread => {
                        50 => 0.02,
                    },
                },
                30 => {
                    smile => {
                        25 => 0.24,
                        50 => 0.18,
                        75 => 0.29,
                    },
                    vol_spread => {
                        50 => 0.02,
                    },
                },
            },
        });
    $delta_surface->save;

    my $c = produce_contract($bet_params2);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/Absolute barrier cannot be zero/, 'Absolute barrier cannot be zero');

    $bet_params2->{barrier} = 101;
    $c = produce_contract($bet_params2);
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'invalid barrier for tick expiry' => sub {
    my $bet_params = {
        date_start => $now,
        date_pricing => $now,
        underlying => 'R_100',
        bet_type => 'CALL',
        duration => '5t',
        barrier => 100,
        currency => 'USD',
        payout => 10,
        current_tick => $fake_tick,
    };
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/Intend to buy tick expiry contract/, 'tick expiry barrier check');
    $bet_params->{barrier} = 'S10P';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{barrier} = 100;
    $bet_params->{bet_type} = 'ASIANU';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'invalid to buy for asian';
    delete $bet_params->{date_pricing};
    $bet_params->{entry_tick} = $fake_tick;
    $bet_params->{exit_tick} = $fake_tick;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell for asian';
};

done_testing();
