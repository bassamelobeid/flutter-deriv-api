#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

my $now = Date::Utility->new(1454284800);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => 'USD'
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        recorded_date => $now,
        symbol        => $_
    }) for qw(1HZ100V 1HZ10V R_100);
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => '1HZ10V',
    epoch      => $now->epoch,
    quote      => 100
});

subtest 'tick expiry for 1HZ' => sub {
    my $args = {
        underlying   => '1HZ10V',
        bet_type     => 'CALL',
        duration     => '5t',
        amount       => 10,
        amount_type  => 'payout',
        currency     => 'USD',
        barrier      => 'S0P',
        current_tick => $tick,
        date_start   => $now,
        date_pricing => $now,
    };
    my $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 5, 'correct contract duration';
    is $c->theo_probability->amount, 0.499992057416873, 'correct theo';
    my $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'CALL_1HZ10V_1454284800_1454284805_100.00', 'checking code';

    $args->{underlying} = '1HZ100V';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 5, 'correct contract duration';
    is $c->theo_probability->amount, 0.499920574169252, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'CALL_1HZ100V_1454284800_1454284805_100.00', 'checking code';

    $args->{underlying} = 'R_100';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 2, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.499887674913696, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'CALL_R_100_1454284800_1454284810_100.00', 'checking code';

    $args->{bet_type} = 'PUT';

    $args->{underlying} = '1HZ10V';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 5, 'correct contract duration';
    is $c->theo_probability->amount, 0.500007942583127, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_1HZ10V_1454284800_1454284805_100.00', 'checking code';

    $args->{underlying} = '1HZ100V';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 5, 'correct contract duration';
    is $c->theo_probability->amount, 0.500079425830748, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_1HZ100V_1454284800_1454284805_100.00', 'checking code';

    #barrier 100.01
    $args->{barrier} = 100.01;
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 5, 'correct contract duration';
    is $c->theo_probability->amount, 0.599219708208553, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_1HZ100V_1454284800_1454284805_100.01', 'checking code';

    $args->{barrier} = 'S0P';

    $args->{underlying} = 'R_100';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 2, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.500112325086304, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_R_100_1454284800_1454284810_100.00', 'checking code';

    #barrier 100.01
    $args->{barrier} = 100.01;
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 2, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.570582147928695, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_R_100_1454284800_1454284810_100.01', 'checking code';

    $args->{underlying} = 'R_10';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 2, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.962115176458186, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_R_10_1454284800_1454284810_100.010', 'checking code';

    $args->{underlying} = '1HZ10V';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 5, 'correct contract duration';
    is $c->theo_probability->amount, 0.993985770038598, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_1HZ10V_1454284800_1454284805_100.01', 'checking code';

#10t contracts
    $args->{bet_type} = 'CALL';
    $args->{duration} = '10t';
    $args->{barrier}  = 'S0P';

    $args->{underlying} = '1HZ10V';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.499988767491223, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'CALL_1HZ10V_1454284800_1454284810_100.00', 'checking code';

    $args->{underlying} = '1HZ100V';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.499887674913696, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'CALL_1HZ100V_1454284800_1454284810_100.00', 'checking code';

    $args->{underlying} = 'R_100';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 2, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 20, 'correct contract duration';
    is $c->theo_probability->amount, 0.499841148341653, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'CALL_R_100_1454284800_1454284820_100.00', 'checking code';

    $args->{bet_type} = 'PUT';

    $args->{underlying} = '1HZ10V';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.500011232508777, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_1HZ10V_1454284800_1454284810_100.00', 'checking code';

    $args->{underlying} = '1HZ100V';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.500112325086304, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_1HZ100V_1454284800_1454284810_100.00', 'checking code';

    #barrier 100.01
    $args->{barrier} = 100.01;
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.570582147928695, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_1HZ100V_1454284800_1454284810_100.01', 'checking code';

    $args->{barrier} = 'S0P';

    $args->{underlying} = 'R_100';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 2, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 20, 'correct contract duration';
    is $c->theo_probability->amount, 0.500158851658347, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_R_100_1454284800_1454284820_100.00', 'checking code';

    #barrier 100.01
    $args->{barrier} = 100.01;
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 2, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 20, 'correct contract duration';
    is $c->theo_probability->amount, 0.550119235669293, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_R_100_1454284800_1454284820_100.01', 'checking code';

    $args->{underlying} = '1HZ10V';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.962115176458186, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_1HZ10V_1454284800_1454284810_100.01', 'checking code';

    $args->{underlying} = 'R_10';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 2, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 20, 'correct contract duration';
    is $c->theo_probability->amount, 0.895384720442124, 'correct theo';
    $code = join '_', ($c->code, $c->underlying->symbol, $c->date_start->epoch, $c->date_expiry->epoch, $c->barrier->as_absolute);
    is $code, 'PUT_R_10_1454284800_1454284820_100.010', 'checking code';
};

done_testing();
