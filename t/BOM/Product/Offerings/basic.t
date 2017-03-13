use strict;
use warnings;

use Test::Most (tests => 4);
use Test::FailWarnings;

use Cache::RedisDB;

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::UnitTestRedis;
use LandingCompany::Offerings qw( get_offerings_flyby get_offerings_with_filter get_permitted_expiries get_contract_specifics );

subtest 'get_offerings_flyby' => sub {
    my $fb;
    lives_ok { $fb = get_offerings_flyby(BOM::Platform::Runtime->instance->get_offerings_config) } 'get_offerings flyby() does not die';
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
                'max_contract_duration',          'min_historical_pricer_duration',
                'max_historical_pricer_duration', 'contract_category_display'
            )
        ],
        'Matching key list'
    );
    eq_or_diff([$fb->values_for_key('expiry_type')], [qw( daily intraday tick )], '..with, at least, the expected values for expiry_type');
    subtest 'example queries' => sub {
        is(scalar $fb->query('"start_type" IS "forward" -> "market"'),          5,  'Forward-starting is offered on 6 markets.');
        is(scalar $fb->query('"expiry_type" IS "tick" -> "underlying_symbol"'), 25, 'Tick expiries are offered on 24 underlyings.');
        is(
            scalar get_offerings_flyby(BOM::Platform::Runtime->instance->get_offerings_config, 'iom')
                ->query('"contract_category" IS "callput" AND "underlying_symbol" IS "frxUSDJPY"'),
            24,
            '24 callput options on frxUSDJPY'
        );
        is(scalar $fb->query('"exchange_name" IS "RANDOM" -> "underlying_symbol"'), 7, 'Six underlyings trade on the RANDOM exchange');
        is(scalar $fb->query('"market" IS "volidx" -> "underlying_symbol"'),        7, '...out of 6 total random market symbols.');
    };

    my $cache_key = LandingCompany::Offerings::_get_config_key(BOM::Platform::Runtime->instance->get_offerings_config);

    my $cache_obj = Cache::RedisDB->get('OFFERINGS_costarica', $cache_key);
    isa_ok $cache_obj, 'FlyBy', 'got flyby object for costarica as its default';
};

subtest 'get_offerings_with_filter' => sub {
    throws_ok { get_offerings_with_filter() } qr/output key/, 'output key is required';

    my $config = BOM::Platform::Runtime->instance->get_offerings_config;

    eq_or_diff [sort(get_offerings_with_filter($config, 'expiry_type'))], [sort qw(daily intraday tick)], 'Expiry types are set correctly here, too.';

    my $filtration = {
        underlying_symbol => 'R_100',
        contract_category => 'callput',
        expiry_type       => 'intraday',
        start_type        => 'spot',
    };
    my $to = 'contract_type';

    eq_or_diff([sort(get_offerings_with_filter($config, $to, $filtration))], [sort qw(CALLE CALL PUT PUTE)], 'Full filter match');
    delete $filtration->{start_type};
    eq_or_diff([sort(get_offerings_with_filter($config, $to, $filtration))], [sort qw(CALLE CALL PUT PUTE)], '... same without start_type');
    delete $filtration->{contract_category};
    eq_or_diff(
        [sort(get_offerings_with_filter($config, $to, $filtration))],
        [sort qw(CALL CALLE PUT EXPIRYRANGE EXPIRYRANGEE EXPIRYMISS ONETOUCH NOTOUCH RANGE SPREADD SPREADU UPORDOWN PUTE)],
        '... explodes without a contract category'
    );
    $filtration->{expiry_type} = 'tick';
    eq_or_diff(
        [sort(get_offerings_with_filter($config, $to, $filtration))],
        [sort qw(CALL CALLE PUT ASIAND ASIANU DIGITMATCH DIGITDIFF DIGITODD DIGITEVEN DIGITOVER DIGITUNDER PUTE)],
        '... and switches up for tick expiries.'
    );

};

subtest 'get_permitted_expiries' => sub {

    my $offerings_config = BOM::Platform::Runtime->instance->get_offerings_config;

    my $r100 = get_permitted_expiries($offerings_config, {underlying_symbol => 'R_100'});

    eq_or_diff(get_permitted_expiries($offerings_config), {}, 'Get an empty result when no guidance is provided.');
    eq_or_diff(
        $r100,
        get_permitted_expiries($offerings_config, {market => 'volidx'}),
        'R_100 has the broadest offering, so it matches with the random market'
    );
    is $r100->{tick}->{min}, 5, "R_100 has something with 5 tick expiries";
    is $r100->{daily}->{max}->days, 365, "... all the way out to a year.";

    my $fx_tnt = get_permitted_expiries(
        $offerings_config,
        {
            market            => 'forex',
            contract_category => 'touchnotouch'
        });
    my $mp_tnt = get_permitted_expiries(
        $offerings_config,
        {
            submarket         => 'minor_pairs',
            contract_category => 'touchnotouch'
        });

    ok !exists $fx_tnt->{intraday}, 'no touchnotouch intraday on fx';
    ok !exists $mp_tnt->{intraday}, '... but not on minor_pairs';
    ok !exists $fx_tnt->{tick},     '... nor does forex have tick touches';
    ok !exists $mp_tnt->{tick},     '... especially not on minor_pairs.';

    my $r100_tnt = get_permitted_expiries(
        $offerings_config,
        {
            underlying_symbol => 'R_100',
            contract_category => 'touchnotouch'
        });
    ok !exists $r100_tnt->{tick},    'None of which is surprising, since they are not on R_100, either';
    ok exists $r100_tnt->{intraday}, '... but you can play them intraday';

    my $r100_digits_tick = get_permitted_expiries(
        $offerings_config,
        {
            underlying_symbol => 'R_100',
            contract_category => 'digits',
            expiry_type       => 'tick',
        });
    my $r100_tnt_tick = get_permitted_expiries(
        $offerings_config,
        {
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

    $params->{barrier_category}  = 'american';
    $params->{underlying_symbol} = 'R_100';
    my $result = get_contract_specifics(BOM::Platform::Runtime->instance->get_offerings_config, $params);

    ok exists $result->{permitted}, 'and permitted durations';
    ok exists $result->{permitted}->{min}, '... including minimum';
    ok exists $result->{permitted}->{max}, '... and maximum';
    ok !exists $result->{historical}, 'but never use an historical pricer';

};

1;
