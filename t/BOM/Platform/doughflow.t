use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Platform::Doughflow qw(get_sportsbook_for_client get_payment_methods);
use BOM::User;
use LandingCompany::Registry;

sub _test_data {
    my $file_name = shift;
    open my $fh, '<', "/home/git/regentmarkets/bom-platform/t/BOM/Platform/$file_name";
    read $fh, my $content, -s $fh;
    close $fh;
    return $content;
}

my $test_usd_ar  = _test_data('test_usd_ar.json');
my $test_usd_br  = _test_data('test_usd_br.json');
my $test_eur_ar  = _test_data('test_eur_ar.json');
my $test_eur_br  = _test_data('test_eur_br.json');
my $test_usd_all = _test_data('test_usd_all.json');
my $test_eur_all = _test_data('test_eur_all.json');

my %dummy_redis_data = (
    'DERIV::CASHIER::PAYMENT_METHODS::1::AR' => $test_usd_ar,
    'DERIV::CASHIER::PAYMENT_METHODS::1::BR' => $test_usd_br,
    'DERIV::CASHIER::PAYMENT_METHODS::2::AR' => $test_eur_ar,
    'DERIV::CASHIER::PAYMENT_METHODS::2::BR' => $test_eur_br,
    'DERIV::CASHIER::PAYMENT_METHODS::1::@'  => $test_usd_all,
    'DERIV::CASHIER::PAYMENT_METHODS::2::@'  => $test_eur_all,
    'Any other key'                          => 'RandomString',
    'More weird keys'                        => '123412341234',
);

my @params;
my $mocked_redis = Test::MockModule->new('RedisDB');
$mocked_redis->mock('scan', sub { [0, [sort keys %dummy_redis_data]]; });
$mocked_redis->mock('get',  sub { shift; my $k = shift; push @params, $k; return $dummy_redis_data{$k}; });

sub get_fiat_currencies {
    my $currencies = shift;
    return grep { $currencies->{$_}->{type} eq 'fiat' } keys %{$currencies};
}

my $config_mocked = Test::MockModule->new('BOM::Config');

subtest 'get_sportsbook' => sub {

    my %valid_sportsbooks = map { $_ => 1 } (
        'Deriv (SVG) LLC USD',
        'Deriv (SVG) LLC EUR',
        'Deriv (SVG) LLC AUD',
        'Deriv (SVG) LLC GBP',
        'Deriv (Europe) Ltd GBP',
        'Deriv (Europe) Ltd EUR',
        'Deriv (Europe) Ltd USD',
        'Deriv (MX) Ltd GBP',
        'Deriv (MX) Ltd USD',
        'Deriv Investments Ltd USD',
        'Deriv Investments Ltd EUR',
        'Deriv Investments Ltd GBP',
        'Deriv (DSL) Ltd USD',
        'Deriv (DSL) Ltd EUR',
        'Deriv (DSL) Ltd GBP',
        'Deriv (DSL) Ltd AUD',
    );

    $config_mocked->mock('on_production', 1);

    for my $lc (LandingCompany::Registry->get_all) {
        next unless $lc->broker_codes->@* && !$lc->is_virtual;

        my @currencies = get_fiat_currencies($lc->legal_allowed_currencies);
        for my $currency (@currencies) {
            my $sportsbook = BOM::Platform::Doughflow::get_sportsbook(
                landing_company => $lc->short,
                currency        => $currency
            );
            ok exists $valid_sportsbooks{$sportsbook}, "'$sportsbook' is a valid Doughflow sportsbook";
        }
    }

    %valid_sportsbooks = map { $_ => 1 } (
        'testenv (SVG) LLC USD',
        'testenv (SVG) LLC EUR',
        'testenv (SVG) LLC AUD',
        'testenv (SVG) LLC GBP',
        'testenv (Europe) Ltd GBP',
        'testenv (Europe) Ltd EUR',
        'testenv (Europe) Ltd USD',
        'testenv (MX) Ltd GBP',
        'testenv (MX) Ltd USD',
        'testenv Investments Ltd USD',
        'testenv Investments Ltd EUR',
        'testenv Investments Ltd GBP',
        'testenv (DSL) Ltd USD',
        'testenv (DSL) Ltd EUR',
        'testenv (DSL) Ltd GBP',
        'testenv (DSL) Ltd AUD',
    );

    $config_mocked->mock('on_production', 0);
    $config_mocked->mock('cashier_env',   'testenv');

    for my $lc (LandingCompany::Registry->get_all) {
        next unless $lc->broker_codes->@* && !$lc->is_virtual;

        my @currencies = get_fiat_currencies($lc->legal_allowed_currencies);
        for my $currency (@currencies) {
            my $sportsbook = BOM::Platform::Doughflow::get_sportsbook(
                landing_company => $lc->short,
                currency        => $currency
            );
            ok exists $valid_sportsbooks{$sportsbook}, "'$sportsbook' is a valid Doughflow sportsbook";
        }
    }

    like(
        exception { BOM::Platform::Doughflow::get_sportsbook(landing_company => 'xxx', currency => 'yyy') },
        qr/^no sportsbook found for xxx/,
        'dies when no sportsbook'
    );
};

subtest 'get_sportsbook_for_client' => sub {
    $config_mocked->mock('on_production', 1);

    my $lc         = LandingCompany::Registry->by_name('svg');
    my @currencies = get_fiat_currencies($lc->legal_allowed_currencies);

    for my $cur (@currencies) {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $client->account($cur);
        my $sbook = get_sportsbook_for_client($client);
        is $sbook, "Deriv (SVG) LLC $cur", $sbook;

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW'});
        $client->account($cur);
        $sbook = get_sportsbook_for_client($client);
        is $sbook, "Deriv (SVG) LLC $cur", $sbook;
    }

    $lc         = LandingCompany::Registry->by_name('maltainvest');
    @currencies = get_fiat_currencies($lc->legal_allowed_currencies);

    for my $cur (@currencies) {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
        $client->account($cur);
        my $sbook = get_sportsbook_for_client($client);
        is $sbook, "Deriv Investments Ltd $cur", $sbook;

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MFW'});
        $client->account($cur);
        $sbook = get_sportsbook_for_client($client);
        is $sbook, "Deriv Investments Ltd $cur", $sbook;
    }
};

subtest 'get_payment_methods' => sub {
    my $dd_trace = {};

    my $df_mock = Test::MockModule->new('BOM::Platform::Doughflow');
    $df_mock->mock(
        'stats_timing',
        sub {
            my ($metric, $time, $tags) = @_;

            $dd_trace->{$metric} = {
                time => $time,
                $tags->%*,
            };

            return undef;
        });

    my $brand   = 'deriv';
    my $country = 'br';
    @params   = ();
    $dd_trace = {};

    $config_mocked->mock('on_production', sub { return 1 });

    my $payment_methods = get_payment_methods($country, $brand);

    cmp_deeply $dd_trace,
        {
        'bom.platform.doughflow.buiding_pm.timing' => {
            time => re('\d+'),
            tags => ['country:br', 'brand:deriv', re('^payment_methods_count:\d+$')],
        },
        'bom.platform.doughflow.deposit_building.timing' => {
            time => re('\d+'),
            tags => ['country:br', 'brand:deriv', re('^deposit_options:\d+$')],
        },
        'bom.platform.doughflow.get_payment_keys.timing' => {
            time => re('\d+'),
            tags => ['country:br', 'brand:deriv'],
        },
        'bom.platform.doughflow.get_redis_data.timing' => {
            time => re('\d+'),
            tags => ['country:br', 'brand:deriv', re('^keys_count:\d+$')],
        },
        'bom.platform.doughflow.payment_methods.timing' => {
            time => re('\d+'),
            tags => ['country:br', 'brand:deriv'],
        },
        'bom.platform.doughflow.payout_building.timing' => {
            time => re('\d+'),
            tags => ['country:br', 'brand:deriv', re('^payout_options:\d+$')],
        },
        },
        'The datadog has been correctly called';

    is(ref $payment_methods, 'ARRAY', 'Returns an ARRAY ref.');
    ok(scalar $payment_methods->@*, 'The array returned is not empty.');
    is(scalar @params, 2,                                        'Get the 2 keys for Brazil');
    is($params[0],     'DERIV::CASHIER::PAYMENT_METHODS::1::BR', 'Redis key for Brazil, sportsbook 1');
    is($params[1],     'DERIV::CASHIER::PAYMENT_METHODS::2::BR', 'Redis key for Brazil, sportsbook 2');

    $brand    = undef;
    $country  = 'ar';
    @params   = ();
    $dd_trace = {};

    $payment_methods = get_payment_methods($country, $brand);

    cmp_deeply $dd_trace,
        {
        'bom.platform.doughflow.buiding_pm.timing' => {
            time => re('\d+'),
            tags => ['country:ar', 'brand:n/a', re('^payment_methods_count:\d+$')],
        },
        'bom.platform.doughflow.deposit_building.timing' => {
            time => re('\d+'),
            tags => ['country:ar', 'brand:n/a', re('^deposit_options:\d+$')],
        },
        'bom.platform.doughflow.get_payment_keys.timing' => {
            time => re('\d+'),
            tags => ['country:ar', 'brand:n/a'],
        },
        'bom.platform.doughflow.get_redis_data.timing' => {
            time => re('\d+'),
            tags => ['country:ar', 'brand:n/a', re('^keys_count:\d+$')],
        },
        'bom.platform.doughflow.payment_methods.timing' => {
            time => re('\d+'),
            tags => ['country:ar', 'brand:n/a'],
        },
        'bom.platform.doughflow.payout_building.timing' => {
            time => re('\d+'),
            tags => ['country:ar', 'brand:n/a', re('^payout_options:\d+$')],
        },
        },
        'The datadog has been correctly called';

    is(ref $payment_methods, 'ARRAY', 'Returns an ARRAY ref. (no brand)');
    ok(scalar $payment_methods->@* > 0, 'Brand param is not passed, the array returned is not empty.');
    is(scalar @params, 2,                                        'Get the 2 keys for Argentina');
    is($params[0],     'DERIV::CASHIER::PAYMENT_METHODS::1::AR', 'Redis key for Argentina, sportsbook 1');
    is($params[1],     'DERIV::CASHIER::PAYMENT_METHODS::2::AR', 'Redis key for Argentina, sportsbook 2');

    $brand    = undef;
    $country  = undef;
    @params   = ();
    $dd_trace = {};

    $payment_methods = get_payment_methods($country, $brand);

    cmp_deeply $dd_trace,
        {
        'bom.platform.doughflow.buiding_pm.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:n/a', re('^payment_methods_count:\d+$')],
        },
        'bom.platform.doughflow.deposit_building.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:n/a', re('^deposit_options:\d+$')],
        },
        'bom.platform.doughflow.get_payment_keys.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:n/a'],
        },
        'bom.platform.doughflow.get_redis_data.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:n/a', re('^keys_count:\d+$')],
        },
        'bom.platform.doughflow.payment_methods.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:n/a'],
        },
        'bom.platform.doughflow.payout_building.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:n/a', re('^payout_options:\d+$')],
        },
        },
        'The datadog has been correctly called';

    is(ref $payment_methods, 'ARRAY', 'Returns an ARRAY ref. (no brand, no country)');
    ok(scalar $payment_methods->@*, 'Brand and country param are not passed, the array returned is not empty.');
    is(scalar @params, 4,                                        'Get all the 4 keys');
    is($params[0],     'DERIV::CASHIER::PAYMENT_METHODS::1::AR', 'Redis key for Argentina, sportsbook 1');
    is($params[1],     'DERIV::CASHIER::PAYMENT_METHODS::1::BR', 'Redis key for Brazil, sportsbook 1');
    is($params[2],     'DERIV::CASHIER::PAYMENT_METHODS::2::AR', 'Redis key for Argentina, sportsbook 2');
    is($params[3],     'DERIV::CASHIER::PAYMENT_METHODS::2::BR', 'Redis key for Brazil, sportsbook 2');

    $brand    = 'binary';
    $country  = undef;
    @params   = ();
    $dd_trace = {};

    $payment_methods = get_payment_methods($country, $brand);

    cmp_deeply $dd_trace,
        {
        'bom.platform.doughflow.buiding_pm.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:binary', re('^payment_methods_count:\d+$')],
        },
        'bom.platform.doughflow.deposit_building.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:binary', re('^deposit_options:\d+$')],
        },
        'bom.platform.doughflow.get_payment_keys.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:binary'],
        },
        'bom.platform.doughflow.get_redis_data.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:binary', re('^keys_count:\d+$')],
        },
        'bom.platform.doughflow.payment_methods.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:binary'],
        },
        'bom.platform.doughflow.payout_building.timing' => {
            time => re('\d+'),
            tags => ['country:all', 'brand:binary', re('^payout_options:\d+$')],
        },
        },
        'The datadog has been correctly called';

    is(ref $payment_methods, 'ARRAY', 'Returns an ARRAY ref. (no country)');
    ok(scalar $payment_methods->@*, 'Country param is not passed, the array returned is not empty.');

    for my $payment_method (@$payment_methods) {
        ok(defined $payment_method->{deposit_limits},       'deposit_limits is present.');
        ok(defined $payment_method->{deposit_time},         'deposit_time is present.');
        ok(defined $payment_method->{description},          'description is present.');
        ok(defined $payment_method->{display_name},         'display_name is present.');
        ok(defined $payment_method->{id},                   'id is present.');
        ok(defined $payment_method->{predefined_amounts},   'predefined_amounts is present.');
        ok(defined $payment_method->{signup_link},          'signup_link is present.');
        ok(defined $payment_method->{supported_currencies}, 'supported_currencies is present.');
        ok(defined $payment_method->{type_display_name},    'type_display_name is present.');
        ok(defined $payment_method->{type},                 'type is present.');
        ok(defined $payment_method->{withdraw_limits},      'withdrawal_limits is present.');
        ok(defined $payment_method->{withdrawal_time},      'withdrawal_time is present.');

        is(ref $payment_method->{deposit_limits},       'HASH',  'deposit_limits is an hash ref.');
        is(ref $payment_method->{predefined_amounts},   'ARRAY', 'predfined_amounts is an array ref.');
        is(ref $payment_method->{supported_currencies}, 'ARRAY', 'supported_currencies is an array ref.');
        is(ref $payment_method->{withdraw_limits},      'HASH',  'withdraw_limits is an hash ref.');
    }
    $config_mocked->unmock('on_production');
};

done_testing;
