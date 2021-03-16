use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Test::MockModule;
use JSON::MaybeXS;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;

my $json = JSON::MaybeXS->new;
BOM::Test::Helper::P2P::bypass_sendbird();

my $runtime_config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$runtime_config->payment_method_countries($json->encode({}));

subtest p2p_payment_methods => sub {

    my $mock_config = Test::MockModule->new('BOM::Config');
    $mock_config->mock(
        'p2p_payment_methods' => {
            bigpay => {
                display_name => 'Big Pay',
                fields       => {account => {display_name => 'Account number'}}
            },
            other => {
                display_name => 'Other',
                fields       => {
                    note => {
                        display_name => 'Note',
                        type         => 'memo',
                        required     => 0
                    }}}});

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'id'
    });

    cmp_deeply($client->p2p_payment_methods, {}, 'no payment methods with empty bo config');
    $runtime_config->payment_method_countries($json->encode({bigpay => {countries => [qw(id mx)]}}));

    cmp_deeply(
        $client->p2p_payment_methods,
        {
            bigpay => {
                display_name => 'Big Pay',
                fields       => {
                    account => {
                        display_name => 'Account number',
                        type         => 'text',
                        required     => 1,
                    }}
            },
        },
        'payment method shown when config has country, and correct field defaults'
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

    cmp_deeply(
        $client->p2p_payment_methods,
        {
            other => {
                display_name => 'Other',
                fields       => {
                    note => {
                        display_name => 'Note',
                        type         => 'memo',
                        required     => 0,
                    }}
            },
        },
        'exclude countries'
    );

};

subtest 'p2p_advertiser_payment_methods' => sub {
    my $client = BOM::Test::Helper::P2P::create_advertiser;

    cmp_deeply(
        $client->p2p_advertiser_payment_methods,
        {
            1 => {
                method     => 'bank_transfer',
                is_enabled => 1,
                fields     => {
                    bank_name => 'placeholder',
                    account   => 'placeholder',
                }}
        },
        'dummy data returned for now'
    );
};

done_testing();
