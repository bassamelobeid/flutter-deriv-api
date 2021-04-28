use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Test::MockModule;
use Test::Fatal;
use JSON::MaybeXS;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;

my $json = JSON::MaybeXS->new;
BOM::Test::Helper::P2P::bypass_sendbird();

my $runtime_config = BOM::Config::Runtime->instance->app_config->payments->p2p;

my $mock_config = Test::MockModule->new('BOM::Config');
$mock_config->mock(
    'p2p_payment_methods' => {
        method1 => {
            display_name => 'Method 1',
            fields       => {
                field1 => {display_name => 'Field 1'},
                field2 => {
                    display_name => 'Field 2',
                    required     => 0
                }}
        },
        method2 => {
            display_name => 'Method 2',
            fields       => {
                field3 => {display_name => 'Field 3'},
                field4 => {display_name => 'Field 4'}}
        },
    });

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    residence   => 'id'
});
$client->account('USD');
my $advertiser;

subtest 'create' => sub {

    cmp_deeply(exception { $client->p2p_advertiser_payment_methods }, {error_code => 'AdvertiserNotRegistered'}, 'advertiser not registered');

    $advertiser = $client->p2p_advertiser_create(name => 'bob');

    cmp_deeply($client->p2p_advertiser_payment_methods, {}, 'new advertiser gets empty list');

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(create => [{method => 'method1', field1 => 'f1 val', field2 => 'field2 val'}]) },
        {
            error_code     => 'InvalidPaymentMethod',
            message_params => ['method1']
        },
        'create non existing method'
    );

    $runtime_config->payment_method_countries(
        $json->encode({
                method1 => {mode => 'exclude'},
                method2 => {mode => 'exclude'}}));

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(create => [{method => 'method1', field3 => 'f3 val'}]) },
        {
            error_code     => 'InvalidPaymentMethodField',
            message_params => ['field3', 'Method 1']
        },
        'Invalid field'
    );

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(create => [{method => 'method1', field2 => 'f2 val'}]) },
        {
            error_code     => 'MissingPaymentMethodField',
            message_params => ['Field 1', 'Method 1']
        },
        'Missing required field'
    );

    cmp_deeply([
            values $client->p2p_advertiser_payment_methods(
                create => [{
                        method     => 'method1',
                        is_enabled => 0,
                        field1     => 'f1 val'
                    },
                    {
                        method => 'method2',
                        field3 => 'f3 val',
                        field4 => 'f4 val'
                    }]
            )->%*
        ],
        bag({
                advertiser_id => $advertiser->{id},
                method        => 'method1',
                is_enabled    => bool(0),
                fields        => {field1 => 'f1 val'}
            },
            {
                advertiser_id => $advertiser->{id},
                method        => 'method2',
                is_enabled    => bool(1),
                fields        => {
                    field3 => 'f3 val',
                    field4 => 'f4 val'
                }}
        ),
        'Create multiple methods ok'
    );

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(create => [{method => 'method2', field3 => 'f3 val', field4 => 'f4 val'}]) },
        {
            error_code     => 'DuplicatePaymentMethod',
            message_params => ['Method 2']
        },
        'Duplicate method'
    );

    cmp_deeply(exception { $client->p2p_advertiser_payment_methods(create => [{method => 'method2', field3 => 'f3 val', field4 => 'f4 new val'}]) },
        undef, 'can create same method with different field values');

    cmp_deeply(
        exception {
            $client->p2p_advertiser_payment_methods(
                create => [{
                        method => 'method1',
                        field1 => 'dupe'
                    },
                    {
                        method => 'method1',
                        field1 => 'dupe'
                    }])
        },
        {
            error_code     => 'DuplicatePaymentMethod',
            message_params => ['Method 1']
        },
        'Duplicate method in same call'
    );

};

subtest 'update' => sub {
    my $existing = $client->p2p_advertiser_payment_methods;
    my ($id) = grep { $existing->{$_}{method} eq 'method1' } keys %$existing;

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(update => {-1 => {is_enabled => 1}}) },
        {error_code => 'PaymentMethodNotFound'},
        'Invalid method id'
    );

    ok $client->p2p_advertiser_payment_methods(update => {$id => {is_enabled => 1}})->{$id}{is_enabled}, 'enable a method';

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(update => {$id => {boo => 'x'}}) },
        {
            error_code     => 'InvalidPaymentMethodField',
            message_params => ['boo', 'Method 1']
        },
        'Invalid field'
    );

    cmp_deeply(
        $client->p2p_advertiser_payment_methods(
            update => {
                $id => {
                    field1 => 'f1 new val',
                    field2 => 'f2 val'
                }}
        )->{$id},
        {
            advertiser_id => $advertiser->{id},
            method        => 'method1',
            is_enabled    => bool(1),
            fields        => {
                field1 => 'f1 new val',
                field2 => 'f2 val'
            }
        },
        'update a field and add another'
    );

    $runtime_config->payment_method_countries($json->encode({method1 => {mode => 'include'}}));
    ok $client->p2p_advertiser_payment_methods(update => {$id => {is_enabled => 0}})->{$id}{is_enabled},
        'update skipped when method disabled in country';
    $runtime_config->payment_method_countries($json->encode({method1 => {mode => 'exclude'}}));

};

subtest 'delete' => sub {
    my $existing = $client->p2p_advertiser_payment_methods;
    my ($id) = grep { $existing->{$_}{method} eq 'method1' } keys %$existing;

    cmp_deeply(exception { $client->p2p_advertiser_payment_methods(delete => [-1]) }, {error_code => 'PaymentMethodNotFound'}, 'Invalid method id');

    is $client->p2p_advertiser_payment_methods(delete => [$id])->{$id}, undef, 'delete ok';

    my @ids = keys $client->p2p_advertiser_payment_methods->%*;
    cmp_deeply($client->p2p_advertiser_payment_methods(delete => \@ids), {}, 'delete everything');

};

subtest 'combo operations' => sub {
    my $existing = $client->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                field1 => 'f1 val'
            }]);
    my ($id) = grep { $existing->{$_}{method} eq 'method1' } keys %$existing;

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(delete => [$id], update => {$id => {field2 => 'f2 val'}}) },
        {error_code => 'PaymentMethodNotFound'},
        'Delete plus update'
    );

    $existing = $client->p2p_advertiser_payment_methods(
        create => [{
                method => 'method1',
                field1 => 'f1 val'
            }]);
    ($id) = grep { $existing->{$_}{method} eq 'method1' } keys %$existing;

    cmp_deeply(
        exception {
            $client->p2p_advertiser_payment_methods(
                update => {$id => {field1 => 'f1 new val'}},
                create => [{
                        method => 'method1',
                        field1 => 'f1 new val'
                    }])
        },
        {
            error_code     => 'DuplicatePaymentMethod',
            message_params => ['Method 1']
        },
        'Update plus create'
    );

};

done_testing();
