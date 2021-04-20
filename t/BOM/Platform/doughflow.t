use strict;
use warnings;

use Test::More;
use Test::MockModule;
use BOM::Config;
use BOM::Config::Runtime;

use BOM::Platform::Doughflow qw(get_sportsbook get_payment_methods);
use LandingCompany::Registry;

my @doughflow_sportsbooks_mock = (
    'Binary (CR) SA USD',
    'Binary (CR) SA EUR',
    'Binary (CR) SA AUD',
    'Binary (CR) SA GBP',
    'Binary (Europe) Ltd GBP',
    'Binary (Europe) Ltd EUR',
    'Binary (Europe) Ltd USD',
    'Binary (IOM) Ltd GBP',
    'Binary (IOM) Ltd USD',
    'Binary Investments Ltd USD',
    'Binary Investments Ltd EUR',
    'Binary Investments Ltd GBP',
);

my @doughflow_deriv_sportsbooks_mock = (
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
);

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

subtest 'doughflow_sportsbooks' => sub {
    my %doughflow_sportsbooks = map { $_ => 1 } @doughflow_sportsbooks_mock;
    my @all_broker_codes      = LandingCompany::Registry->all_broker_codes;

    my $config_mocked = Test::MockModule->new('BOM::Config');
    $config_mocked->mock('on_production', sub { return 1 });

    BOM::Config::Runtime->instance->app_config->system->suspend->doughflow_deriv_sportsbooks(1);    # disable Deriv sportsbooks

    for my $broker (@all_broker_codes) {
        my $lc = LandingCompany::Registry->get_by_broker($broker);

        next if $lc->short =~ /virtual|champion/;

        my @currencies = get_fiat_currencies($lc->legal_allowed_currencies);
        for my $currency (@currencies) {
            my $sportsbook = get_sportsbook($broker, $currency);
            ok exists $doughflow_sportsbooks{$sportsbook}, "'$sportsbook' exists in Doughflow sportsbooks";
        }
    }

    $config_mocked->unmock('on_production');
};

subtest 'doughflow_deriv_sportsbooks' => sub {
    my %doughflow_sportsbooks = map { $_ => 1 } @doughflow_deriv_sportsbooks_mock;
    my @all_broker_codes      = LandingCompany::Registry->all_broker_codes;

    my $config_mocked = Test::MockModule->new('BOM::Config');
    $config_mocked->mock('on_production', sub { return 1 });

    BOM::Config::Runtime->instance->app_config->system->suspend->doughflow_deriv_sportsbooks(0);    # enable Deriv sportsbooks

    for my $broker (@all_broker_codes) {
        my $lc = LandingCompany::Registry->get_by_broker($broker);

        next if $lc->short =~ /virtual|champion/;

        my @currencies = get_fiat_currencies($lc->legal_allowed_currencies);
        for my $currency (@currencies) {
            my $sportsbook = get_sportsbook($broker, $currency);
            ok exists $doughflow_sportsbooks{$sportsbook}, "'$sportsbook' exists in Doughflow sportsbooks";
        }
    }

    $config_mocked->unmock('on_production');
};

subtest 'doughflow deriv sportsbook landing company consistency' => sub {
    my @all_broker_codes = LandingCompany::Registry->all_broker_codes;

    for my $broker (@all_broker_codes) {
        my $lc = LandingCompany::Registry->get_by_broker($broker);

        next if $lc->short =~ /virtual|champion|samoa/;

        my $sportsbook = BOM::Platform::Doughflow::get_sportsbook_mapping_by_landing_company($lc->short);
        next unless $sportsbook;

        my ($sportsbook_first_two_words) = $sportsbook =~ /^([A-Za-z]*\s\(*[A-Za-z]*\)*)/;

        my ($lc_first_two_words) = $lc->name =~ /^([A-Za-z]*\s\(*[A-Za-z]*\)*)/;
        is($sportsbook_first_two_words, $lc_first_two_words,
            "Sportsbook starts with $sportsbook_first_two_words and it matches landing company that starts with $lc_first_two_words");
    }
};

subtest 'get_payment_methods' => sub {

    my $brand   = 'deriv';
    my $country = 'br';
    @params = ();

    my $payment_methods = get_payment_methods($country, $brand);

    is(ref $payment_methods, 'ARRAY', 'Returns an ARRAY ref.');
    ok(scalar $payment_methods->@*, 'The array returned is not empty.');
    is(scalar @params, 2,                                        'Get the 2 keys for Brazil');
    is($params[0],     'DERIV::CASHIER::PAYMENT_METHODS::1::BR', 'Redis key for Brazil, sportsbook 1');
    is($params[1],     'DERIV::CASHIER::PAYMENT_METHODS::2::BR', 'Redis key for Brazil, sportsbook 2');

    $brand   = undef;
    $country = 'ar';
    @params  = ();

    $payment_methods = get_payment_methods($country, $brand);

    is(ref $payment_methods, 'ARRAY', 'Returns an ARRAY ref. (no brand)');
    ok(scalar $payment_methods->@* > 0, 'Brand param is not passed, the array returned is not empty.');
    is(scalar @params, 2,                                        'Get the 2 keys for Argentina');
    is($params[0],     'DERIV::CASHIER::PAYMENT_METHODS::1::AR', 'Redis key for Argentina, sportsbook 1');
    is($params[1],     'DERIV::CASHIER::PAYMENT_METHODS::2::AR', 'Redis key for Argentina, sportsbook 2');

    $brand   = undef;
    $country = undef;
    @params  = ();

    $payment_methods = get_payment_methods($country, $brand);

    is(ref $payment_methods, 'ARRAY', 'Returns an ARRAY ref. (no brand, no country)');
    ok(scalar $payment_methods->@*, 'Brand and country param are not passed, the array returned is not empty.');
    is(scalar @params, 2,                                       'Get all the 2 keys');
    is($params[0],     'DERIV::CASHIER::PAYMENT_METHODS::1::@', 'Redis key for global, sportsbook 1');
    is($params[1],     'DERIV::CASHIER::PAYMENT_METHODS::2::@', 'Redis key for global, sportsbook 2');

    $brand   = 'binary';
    $country = undef;
    @params  = ();

    $payment_methods = get_payment_methods($country, $brand);

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
};

done_testing;
