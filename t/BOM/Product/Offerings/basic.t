use strict;
use warnings;

use Test::Most (tests => 5);
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::Product::Offerings
    qw( get_offerings_flyby get_offerings_with_filter get_permitted_expiries get_historical_pricer_durations get_contract_specifics );

subtest 'get_offerings_flyby' => sub {
    my $fb;
    lives_ok { $fb = get_offerings_flyby() } 'get_offerings flyby() does not die';
    isa_ok $fb, 'FlyBy', '...and resulting object';
    cmp_ok(scalar @{$fb->records}, '>=', 600, '...with over 600 varieties.');
    eq_or_diff(
        [sort $fb->all_keys],
        [
            sort { $a cmp $b } (
                'barrier_category',               'contract_category',
                'contract_type',                  'contract_display',
                'expiry_type',                    'market',
                'exchange_name',                  'sentiment',
                'start_type',                     'submarket',
                'underlying_symbol',              'min_contract_duration',
                'max_contract_duration',          'payout_limit',
                'min_historical_pricer_duration', 'max_historical_pricer_duration',
                'contract_category_display'
            )
        ],
        'Matching key list'
    );
    eq_or_diff([$fb->values_for_key('expiry_type')], [qw( daily intraday tick )], '..with, at least, the expected values for expiry_type');
    subtest 'example queries' => sub {
        is(scalar $fb->query('"start_type" IS "forward" -> "market"'),          5,  'Forward-starting is offered on 5 markets.');
        is(scalar $fb->query('"expiry_type" IS "tick" -> "underlying_symbol"'), 12, 'Tick expiries are offered on 12 underlyings.');
        is(scalar get_offerings_flyby('iom')->query('"contract_category" IS "callput" AND "underlying_symbol" IS "frxUSDJPY"'), 10, '10 callput options on frxUSDJPY');
        is(scalar $fb->query('"exchange_name" IS "RANDOM" -> "underlying_symbol"'), 8,  'Eight underlyings trade on the RANDOM exchange');
        is(scalar $fb->query('"market" IS "random" -> "underlying_symbol"'),        12, '...out of 12 total random market symbols.');
    };
};

subtest 'get_offerings_with_filter' => sub {
    throws_ok { get_offerings_with_filter() } qr/output key/, 'output key is required';

    eq_or_diff [sort(get_offerings_with_filter('expiry_type'))], [sort qw(daily intraday tick)], 'Expiry types are set correctly here, too.';

    my $filtration = {
        underlying_symbol => 'R_100',
        contract_category => 'callput',
        expiry_type       => 'intraday',
        start_type        => 'spot',
    };
    my $to = 'contract_type';

    eq_or_diff([sort(get_offerings_with_filter($to, $filtration))], [sort qw(CALL PUT)], 'Full filter match');
    delete $filtration->{start_type};
    eq_or_diff([sort(get_offerings_with_filter($to, $filtration))], [sort qw(CALL PUT)], '... same without start_type');
    delete $filtration->{contract_category};
    eq_or_diff(
        [sort(get_offerings_with_filter($to, $filtration))],
        [sort qw(CALL PUT EXPIRYRANGE EXPIRYMISS ONETOUCH NOTOUCH RANGE SPREADD SPREADU UPORDOWN)],
        '... explodes without a contract category'
    );
    $filtration->{expiry_type} = 'tick';
    eq_or_diff(
        [sort(get_offerings_with_filter($to, $filtration))],
        [sort qw(CALL PUT ASIAND ASIANU DIGITMATCH DIGITDIFF DIGITODD DIGITEVEN DIGITOVER DIGITUNDER)],
        '... and switches up for tick expiries.'
    );

};

subtest 'get_permitted_expiries' => sub {

    my $r100 = get_permitted_expiries({underlying_symbol => 'R_100'});

    eq_or_diff(get_permitted_expiries(), {}, 'Get an empty result when no guidance is provided.');
    eq_or_diff($r100, get_permitted_expiries({market => 'random'}), 'R_100 has the broadest offering, so it matches with the random market');
    is $r100->{tick}->{min}, 5, "R_100 has something with 5 tick expiries";
    is $r100->{daily}->{max}->days, 365, "... all the way out to a year.";

    my $fx_tnt = get_permitted_expiries({
        market            => 'forex',
        contract_category => 'touchnotouch'
    });
    my $mp_tnt = get_permitted_expiries({
        submarket         => 'minor_pairs',
        contract_category => 'touchnotouch'
    });

    ok !exists $fx_tnt->{intraday},  'no touchnotouch intraday on fx';
    ok !exists $mp_tnt->{intraday}, '... but not on minor_pairs';
    ok !exists $fx_tnt->{tick},     '... nor does forex have tick touches';
    ok !exists $mp_tnt->{tick},     '... especially not on minor_pairs.';

    my $r100_tnt = get_permitted_expiries({
        underlying_symbol => 'R_100',
        contract_category => 'touchnotouch'
    });
    ok !exists $r100_tnt->{tick},    'None of which is surprising, since they are not on R_100, either';
    ok exists $r100_tnt->{intraday}, '... but you can play them intraday';

    my $r100_digits_tick = get_permitted_expiries({
        underlying_symbol => 'R_100',
        contract_category => 'digits',
        expiry_type       => 'tick',
    });
    my $r100_tnt_tick = get_permitted_expiries({
        underlying_symbol => 'R_100',
        contract_category => 'touchnotouch',
        expiry_type       => 'tick',
    });

    ok exists $r100_digits_tick->{min} && exists $r100_digits_tick->{max}, 'Asking for a relevant tick expiry, gives just that min and max';
    eq_or_diff($r100_tnt_tick, {}, '... but get an empty reference if they are not there.');
};

subtest 'get_historical_pricer_durations' => sub {

    my $r100 = get_historical_pricer_durations({underlying_symbol => 'R_100'});

    eq_or_diff(get_historical_pricer_durations({underlying_symbol => 'R_100'}),
        {}, 'Randoms do not use the historical pricer, so the durations are empty');
    my $eu_cp = get_historical_pricer_durations({
        underlying_symbol => 'frxEURUSD',
        contract_category => 'callput'
    });
    ok exists $eu_cp->{intraday}, 'EUR/USD callput has intraday durations';
    ok !exists $eu_cp->{daily},   '... but not daily';
    ok !exists $eu_cp->{tick},    '... nor tick';

    my $eu_tnt = get_historical_pricer_durations({
        underlying_symbol => 'frxEURUSD',
        contract_category => 'touchnotouch'
    });
    use BOM::Market::Underlying;
    my $eu = BOM::Market::Underlying->new('frxEURUSD');

    ok !exists $eu_tnt->{intraday}, 'EUR/USD touchnotouch has intraday durations';
    ok !exists $eu_tnt->{daily},   '... but not daily';
    ok !exists $eu_tnt->{tick},    '... nor tick';
    SKIP: {
        skip 'skip because of euro pairs offerings adjustment', 2 unless exists $eu_tnt->{intraday};
        cmp_ok $eu_cp->{intraday}->{min}->seconds, '<',  $eu_tnt->{intraday}->{min}->seconds, 'callputs have shorter minimums';
        cmp_ok $eu_cp->{intraday}->{max}->seconds, '==', 18000, '5h eu callput';
        cmp_ok $eu_tnt->{intraday}->{max}->seconds, '==', 18000, '5h tnt';
    }

    my $r100_digits_tick = get_permitted_expiries({
        underlying_symbol => 'R_100',
        contract_category => 'digits',
        expiry_type       => 'tick',
    });
    my $r100_tnt_tick = get_historical_pricer_durations({
        underlying_symbol => 'R_100',
        contract_category => 'touchnotouch',
        expiry_type       => 'tick',
    });

    ok exists $r100_digits_tick->{min} && exists $r100_digits_tick->{max}, 'Asking for a relevant tick expiry, gives just that min and max';
    eq_or_diff($r100_tnt_tick, {}, '... but get an empty reference if they are not there.');
};

subtest 'get_contract_specifics' => sub {

    throws_ok { get_contract_specifics() } qr/Improper arguments/, 'Need to supply required parameters.';
    my $params = {
        underlying_symbol => 'frxUSDJPY',
        contract_category => 'touchnotouch',
        start_type        => 'spot',
        expiry_type       => 'intraday'
    };
    throws_ok { get_contract_specifics($params) } qr/Improper arguments/, '... ALL required parameters.';

    $params->{barrier_category} = 'euro_atm';

    my $default_payout = {
        payout_limit => {
            USD => 100000,
            AUD => 100000,
            GBP => 100000,
            EUR => 100000,
            JPY => 10000000,
        }};
    eq_or_diff(get_contract_specifics($params), $default_payout, 'Non-matching parameters yield just a default payout limit');
    $params->{barrier_category} = 'american';
    my $result = get_contract_specifics($params);

    ok exists $result->{payout_limit}, 'Things which can be sold also have the payout_limit set';

    $params->{underlying_symbol} = 'R_100';
    $result = get_contract_specifics($params);

    ok exists $result->{payout_limit}, 'Randoms also have the payout_limit set';
    ok exists $result->{permitted},    'and permitted durations';
    ok exists $result->{permitted}->{min}, '... including minimum';
    ok exists $result->{permitted}->{max}, '... and maximum';
    ok !exists $result->{historical}, 'but never use an historical pricer';

};

1;
