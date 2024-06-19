use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::Warn;
use Test::MockModule;
use JSON::MaybeXS;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use BOM::Config::P2P;
my $json = JSON::MaybeXS->new;
BOM::Test::Helper::P2P::bypass_sendbird();

my $runtime_config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$runtime_config->payment_method_countries($json->encode({}));
$runtime_config->payment_methods_enabled(1);
$runtime_config->restricted_countries(['ng']);

subtest p2p_country_list => sub {

    my $mock_config = Test::MockModule->new('BOM::Config');
    $mock_config->mock(
        'p2p_payment_methods' => {
            bigpay => {
                display_name => 'Big Pay',
                type         => 'ewallet',
                fields       => {account => {display_name => 'Account number'}}
            },
            other => {
                display_name => 'Other',
                type         => 'other',
                fields       => {
                    note => {
                        display_name => 'Note',
                        type         => 'memo',
                        required     => 0
                    }}
            },
            upi => {
                display_name => 'Unified Payments Interface (UPI)',
                type         => 'bank',
                fields       => {account => {display_name => 'UPI ID'}}}});

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'id'
    });
    my $p2p_client = P2P->new(client => $client);

    cmp_deeply(
        exception {
            $p2p_client->p2p_country_list(country => 'ng')
        },
        {error_code => 'RestrictedCountry'},
        " error code in case country code is invalid"
    );

    cmp_deeply(
        exception {
            $p2p_client->p2p_country_list(country => 'idd')
        },
        {error_code => 'RestrictedCountry'},
        " error code in case country code is invalid"
    );

    cmp_deeply(
        $p2p_client->p2p_country_list(country => 'id'),
        {
            id => {
                country_name             => 'Indonesia',
                local_currency           => 'IDR',
                float_rate_offset_limit  => '5.00',
                cross_border_ads_enabled => 1,
                fixed_rate_adverts       => 'enabled',
                float_rate_adverts       => 'disabled',
                payment_methods          => {}}
        },
        'no payment methods available for Indonesia'
    );

    cmp_deeply(
        $p2p_client->p2p_country_list(country => 'in'),
        {
            in => {
                country_name             => 'India',
                local_currency           => 'INR',
                float_rate_offset_limit  => '5.00',
                cross_border_ads_enabled => 1,
                fixed_rate_adverts       => 'enabled',
                float_rate_adverts       => 'disabled',
                payment_methods          => {}}
        },
        'no payment methods available for India'
    );

    $runtime_config->payment_method_countries($json->encode({bigpay => {countries => [qw(id mx)]}}));
    delete $p2p_client->{_payment_method_countries_cached};

    cmp_deeply(
        $p2p_client->p2p_country_list(country => 'id'),
        {
            id => {
                country_name             => 'Indonesia',
                local_currency           => 'IDR',
                float_rate_offset_limit  => '5.00',
                cross_border_ads_enabled => 1,
                fixed_rate_adverts       => 'enabled',
                float_rate_adverts       => 'disabled',
                payment_methods          => {
                    bigpay => {
                        display_name => 'Big Pay',
                        type         => 'ewallet',
                        fields       => {
                            account => {
                                display_name => 'Account number',
                                type         => 'text',
                                required     => 1,
                            },
                            instructions => {
                                display_name => 'Instructions',
                                type         => 'memo',
                                required     => 0,
                            }}}}}

        },
        'payment method field populated since BigPay is available in Indonesia'
    );

    $runtime_config->payment_method_countries($json->encode({upi => {countries => [qw(in)]}}));
    delete $p2p_client->{_payment_method_countries_cached};

    cmp_deeply(
        $p2p_client->p2p_country_list(country => 'in'),
        {
            in => {
                country_name             => 'India',
                local_currency           => 'INR',
                float_rate_offset_limit  => '5.00',
                cross_border_ads_enabled => 1,
                fixed_rate_adverts       => 'enabled',
                float_rate_adverts       => 'disabled',
                payment_methods          => {
                    upi => {
                        display_name => 'Unified Payments Interface (UPI)',
                        type         => 'bank',
                        fields       => {
                            account => {
                                display_name => 'UPI ID',
                                type         => 'text',
                                required     => 1,
                            },
                            instructions => {
                                display_name => 'Instructions',
                                type         => 'memo',
                                required     => 0,
                            }}}}}

        },
        'payment method shown when config updated for india, and correct field defaults'
    );

    $runtime_config->payment_method_countries(
        $json->encode({
                bigpay => {
                    mode      => 'exclude',
                    countries => [qw(id)]
                },
                other => {
                    mode      => 'exclude',
                    countries => [qw(mx)]}}));

    delete $p2p_client->{_payment_method_countries_cached};

    cmp_deeply(
        $p2p_client->p2p_country_list(country => 'id'),
        {
            id => {
                country_name             => 'Indonesia',
                local_currency           => 'IDR',
                float_rate_offset_limit  => '5.00',
                cross_border_ads_enabled => 1,
                fixed_rate_adverts       => 'enabled',
                float_rate_adverts       => 'disabled',
                payment_methods          => {
                    other => {
                        display_name => 'Other',
                        type         => 'other',
                        fields       => {
                            note => {
                                display_name => 'Note',
                                type         => 'memo',
                                required     => 0,
                            },
                            instructions => {
                                display_name => 'Instructions',
                                type         => 'memo',
                                required     => 0,
                            }}}}}
        },
        'exclude countries'
    );

    is keys $p2p_client->p2p_country_list()->%*, keys BOM::Config::P2P->available_countries()->%*, "returning all the countries";

};

done_testing();
