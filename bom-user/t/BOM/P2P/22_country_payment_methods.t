use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Test::MockModule;
use JSON::MaybeXS;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2PWithClient;
use BOM::Test::Customer;
use BOM::Config::Runtime;

my $json = JSON::MaybeXS->new;
BOM::Test::Helper::P2PWithClient::bypass_sendbird();

my $runtime_config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$runtime_config->payment_method_countries($json->encode({}));

subtest p2p_payment_methods => sub {

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

    my $test_customer = BOM::Test::Customer->create(
        residence => 'id',
        clients   => [{
                name        => 'CR',
                broker_code => 'CR',
            }]);
    my $client = $test_customer->get_client_object('CR');

    my $test_customer_in = BOM::Test::Customer->create(
        residence => 'in',
        clients   => [{
                name        => 'CR',
                broker_code => 'CR',
            }]);
    my $india_client = $test_customer_in->get_client_object('CR');

    cmp_deeply($client->p2p_payment_methods('id'),       {}, 'no payment methods with empty bo config');
    cmp_deeply($india_client->p2p_payment_methods('in'), {}, 'no payment methods with empty bo config');

    $runtime_config->payment_method_countries($json->encode({bigpay => {countries => [qw(id mx)]}}));

    cmp_deeply(
        $client->p2p_payment_methods('id'),
        {
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
                    }}
            },
        },
        'payment method shown when config has country, and correct field defaults'
    );

    $runtime_config->payment_method_countries($json->encode({upi => {countries => [qw(in)]}}));

    cmp_deeply(
        $india_client->p2p_payment_methods('in'),
        {
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
                    }}}
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

    cmp_deeply(
        $client->p2p_payment_methods('id'),
        {
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
                    }}
            },
        },
        'exclude countries'
    );

};

done_testing();
