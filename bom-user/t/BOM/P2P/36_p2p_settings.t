use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;
use JSON::MaybeXS qw(encode_json);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Redis;

my $email = 'user@binary.com';

my $user = BOM::User->create(
    email    => $email,
    password => 'test'
);

my $test_client_id = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    binary_user_id => $user->id,
    residence      => 'id',
});

subtest 'p2p_settings' => sub {

    my $config        = BOM::Config::Runtime->instance->app_config;
    my $p2p_config    = $config->payments->p2p;
    my $mock_currency = Test::MockModule->new('BOM::Config::CurrencyConfig');
    my %currencies    = (
        AAA => {
            name      => 'AAA currency',
            countries => ['id']
        },
        BBB => {
            name      => 'BBB currency',
            countries => ['ng', 'br']
        },
        CCC => {
            name      => 'CCC currency',
            countries => ['au', 'nz']
        },    # blocked countries for p2p
    );

    $p2p_config->restricted_countries(['au', 'nz', 'id']);
    $p2p_config->available_for_currencies(['usd']);
    $p2p_config->cross_border_ads_restricted_countries([]);
    $p2p_config->order_expiry_options([900, 1800, 2700, 3600]);
    %BOM::Config::CurrencyConfig::ALL_CURRENCIES = %currencies;
    $mock_currency->redefine(local_currency_for_country => sub { my %params = @_; return 'AAA' if $params{country} eq 'id' });
    BOM::Config::Redis->redis_p2p_write->set('P2P::LOCAL_CURRENCIES', 'BBB,CCC');

    my %vals = (
        adverts_active_limit        => 1,
        adverts_archive_period      => 2,
        cancellation_block_duration => 3,
        cancellation_count_period   => 4,
        cancellation_grace_period   => 5,
        cancellation_limit          => 6,
        maximum_advert_amount       => 7,
        maximum_order_amount        => 8,
        order_daily_limit           => 9,
        order_expiry_options        => [900, 1800, 2700, 3600],
        order_payment_period        => 10,
        supported_currencies        => ["usd"],
        disabled                    => bool(0),
        payment_methods_enabled     => bool(1),
        fixed_rate_adverts          => 'disabled',
        float_rate_adverts          => 'list_only',
        float_rate_offset_limit     => num(4.10),
        fixed_rate_adverts_end_date => '2012-02-03',
        review_period               => 13,
        feature_level               => 14,
        override_exchange_rate      => num(123.45),
        cross_border_ads_enabled    => 1,
        local_currencies            => [{
                symbol       => 'AAA',
                display_name => $currencies{AAA}->{name},
                is_default   => 1,
                has_adverts  => 0,
            },
            {
                symbol       => 'BBB',
                display_name => $currencies{BBB}->{name},
                has_adverts  => 1,
            },
        ],
        block_trade => {
            disabled              => 0,
            maximum_advert_amount => 15,
        },
        counterparty_term_steps => {
            completion_rate => [10,  33,  99],
            join_days       => [9,   27,  88],
            rating          => [2.3, 3.6, 4.7],
        },
        business_hours_minutes_interval => 16,
    );

    $p2p_config->available(1);
    $p2p_config->archive_ads_days($vals{adverts_archive_period});
    $p2p_config->limits->maximum_ads_per_type($vals{adverts_active_limit});
    $p2p_config->cancellation_barring->bar_time($vals{cancellation_block_duration});
    $p2p_config->cancellation_barring->period($vals{cancellation_count_period});
    $p2p_config->cancellation_grace_period($vals{cancellation_grace_period});
    $p2p_config->cancellation_barring->count($vals{cancellation_limit});
    $p2p_config->limits->maximum_advert($vals{maximum_advert_amount});
    $p2p_config->limits->maximum_order($vals{maximum_order_amount});
    $p2p_config->limits->count_per_day_per_client($vals{order_daily_limit});
    $p2p_config->order_timeout($vals{order_payment_period} * 60);
    $p2p_config->review_period($vals{review_period});
    $p2p_config->feature_level($vals{feature_level});
    $p2p_config->enabled(1);
    $config->system->suspend->p2p(0);
    $p2p_config->payment_methods_enabled(1);
    $p2p_config->float_rate_global_max_range(8.2);
    $p2p_config->country_advert_config(
        encode_json({
                'id' => {
                    float_ads        => 'list_only',
                    fixed_ads        => 'disabled',
                    deactivate_fixed => '2012-02-03'
                }}));

    $p2p_config->currency_config(
        encode_json({
                'AAA' => {
                    max_rate_range     => 8.2,
                    manual_quote       => 123.45,
                    manual_quote_epoch => time + 100,
                }}));
    $p2p_config->block_trade->enabled(1);
    $p2p_config->block_trade->maximum_advert(15);
    $p2p_config->advert_counterparty_terms->completion_rate_steps($vals{counterparty_term_steps}{completion_rate});
    $p2p_config->advert_counterparty_terms->join_days_steps($vals{counterparty_term_steps}{join_days});
    $p2p_config->advert_counterparty_terms->rating_steps($vals{counterparty_term_steps}{rating});
    $p2p_config->business_hours_minutes_interval($vals{business_hours_minutes_interval});

    cmp_deeply(
        exception {
            $test_client_id->p2p_settings()
        },
        {
            error_code => 'RestrictedCountry',
        },
        'Clients from P2P restricted country cannot access P2P settings endpoint'
    );

    $p2p_config->restricted_countries(['au', 'nz']);
    my $resp = $test_client_id->p2p_settings();
    cmp_deeply($resp, \%vals, 'expected results from runtime config');

    $config->system->suspend->p2p(1);
    is $test_client_id->p2p_settings()->{disabled}, 1, 'p2p suspended';

    $config->system->suspend->p2p(0);
    $p2p_config->enabled(0);
    is $test_client_id->p2p_settings()->{disabled}, 1, 'p2p disabled';

    $config->system->suspend->p2p(0);
    $p2p_config->enabled(1);
    is $test_client_id->p2p_settings()->{disabled}, 0, 'p2p enabled';
};

done_testing();
