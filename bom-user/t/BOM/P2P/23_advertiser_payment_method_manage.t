use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;
use Test::MockModule;
use Test::Fatal;
use JSON::MaybeXS;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2PWithClient;
use BOM::Config::Runtime;

my $json = JSON::MaybeXS->new;
BOM::Test::Helper::P2PWithClient::bypass_sendbird();

my @emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push @emitted_events, [@_] });

my $pm_config = +{
    paypal => {
        display_name => 'PayPal',
        type         => 'ewallet',
        fields       => {
            account => {display_name => 'Email or phone number'},
        }
    },
    btc_smega => {
        display_name => 'BTC SMEGA',
        type         => 'ewallet',
        fields       => {
            account => {display_name => 'BTC SMEGA account'},
        },
        keywords => ['btcsmega']
    },
    bank_transfer => {
        display_name => 'Bank Transfer',
        type         => 'bank',
        fields       => {
            account   => {display_name => 'Account Number'},
            bank_name => {display_name => 'Bank Name'},
            bank_code => {
                display_name => 'SWIFT or IFSC code',
                required     => 0,
            }
        },
        keywords => ['bank']
    },
    other => {
        display_name => 'Other',
        type         => 'other',
        fields       => {
            account => {display_name => 'Account ID / phone number / email'},
            name    => {display_name => 'Payment method name'},
        }}};

my $mock_config = Test::MockModule->new('BOM::Config');
$mock_config->mock('p2p_payment_methods' => $pm_config);

my $runtime_config = BOM::Config::Runtime->instance->app_config->payments->p2p;
$runtime_config->payment_methods_enabled(1);

my $pm_country_config = +{map { $_ => {mode => 'exclude'} } keys %$pm_config};
$runtime_config->payment_method_countries($json->encode($pm_country_config));

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    residence   => 'id'
});

$client->account('USD');
my ($advertiser, $client2, $client3);

subtest 'create' => sub {

    $runtime_config->payment_methods_enabled(0);

    cmp_deeply(exception { $client->p2p_advertiser_payment_methods }, {error_code => 'AdvertiserNotRegistered'}, 'advertiser not registered');

    $advertiser = $client->p2p_advertiser_create(name => 'bob');

    cmp_deeply($client->p2p_advertiser_payment_methods, {}, 'new advertiser gets empty list');

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(create => [{method => 'paypal', account => '123', instructions => 'please pay!'}]) },
        {
            error_code => 'PaymentMethodsDisabled',
        },
        'pm feature disabled'
    );

    $runtime_config->payment_methods_enabled(1);
    $pm_country_config->{paypal}{mode} = 'include';
    $runtime_config->payment_method_countries($json->encode($pm_country_config));
    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(create => [{method => 'paypal', account => '123', instructions => 'please pay!'}]) },
        {
            error_code     => 'InvalidPaymentMethod',
            message_params => ['paypal']
        },
        'create non existing method'
    );

    $pm_country_config->{paypal}{mode} = 'exclude';
    $runtime_config->payment_method_countries($json->encode($pm_country_config));

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(create => [{method => 'paypal', code => 'a249'}]) },
        {
            error_code     => 'InvalidPaymentMethodField',
            message_params => ['code', 'PayPal']
        },
        'Invalid field'
    );

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(create => [{method => 'paypal', instructions => 'please pay!'}]) },
        {
            error_code     => 'MissingPaymentMethodField',
            message_params => ['Email or phone number', 'PayPal']
        },
        'Missing required field'
    );

    @emitted_events = ();

    cmp_deeply([
            values $client->p2p_advertiser_payment_methods(
                create => [{
                        method     => 'paypal',
                        is_enabled => 0,
                        account    => '123'
                    },
                    {
                        method       => 'bank_transfer',
                        account      => '123zz',
                        bank_name    => 'HSBC',
                        instructions => 'transfer to account'
                    },
                    {
                        method       => 'btc_smega',
                        account      => '456',
                        instructions => 'please pay!'
                    }]
            )->%*
        ],
        bag({
                method       => 'paypal',
                type         => 'ewallet',
                display_name => 'PayPal',
                is_enabled   => bool(0),
                fields       => {
                    account => {
                        value        => '123',
                        display_name => 'Email or phone number',
                        type         => 'text',
                        required     => bool(1)
                    },
                    instructions => {
                        display_name => 'Instructions',
                        required     => 0,
                        type         => 'memo',
                        value        => ''
                    }
                },
                used_by_adverts => undef,
                used_by_orders  => undef,
            },
            {
                method       => 'bank_transfer',
                type         => 'bank',
                display_name => 'Bank Transfer',
                is_enabled   => bool(1),
                fields       => {
                    account => {
                        value        => '123zz',
                        display_name => 'Account Number',
                        type         => 'text',
                        required     => bool(1)
                    },
                    bank_name => {
                        value        => 'HSBC',
                        display_name => 'Bank Name',
                        type         => 'text',
                        required     => bool(1)
                    },
                    bank_code => {
                        value        => '',
                        display_name => 'SWIFT or IFSC code',
                        type         => 'text',
                        required     => bool(0)
                    },
                    instructions => {
                        display_name => 'Instructions',
                        required     => 0,
                        type         => 'memo',
                        value        => 'transfer to account'
                    }
                },
                used_by_adverts => undef,
                used_by_orders  => undef,
            },
            {
                method       => 'btc_smega',
                type         => 'ewallet',
                display_name => 'BTC SMEGA',
                is_enabled   => bool(1),
                fields       => {
                    account => {
                        value        => '456',
                        display_name => 'BTC SMEGA account',
                        type         => 'text',
                        required     => bool(1)
                    },
                    instructions => {
                        display_name => 'Instructions',
                        required     => 0,
                        type         => 'memo',
                        value        => 'please pay!'
                    },
                },
                used_by_adverts => undef,
                used_by_orders  => undef,
            }
        ),
        'Create multiple methods ok'
    );

    ok !@emitted_events, 'no events for create';

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(create => [{method => 'paypal', account => '123', instructions => 'contact me'}]) },
        {
            error_code     => 'DuplicatePaymentMethod',
            message_params => ['PayPal']
        },
        "Duplicates within client's existing payment methods"
    );

    cmp_deeply(
        exception {
            $client->p2p_advertiser_payment_methods(
                create => [{
                        method       => 'paypal',
                        account      => '123',
                        instructions => 'contact me?'
                    },
                    {
                        method       => 'bank_transfer',
                        account      => 'hsbc345',
                        bank_name    => 'HSBC',
                        instructions => 'contact me?'
                    }])
        },
        {
            error_code     => 'DuplicatePaymentMethod',
            message_params => ['PayPal']
        },
        "Since one entry in array has a duplicate match with advertier's existing pms, pm create failed"
    );

    my $existing = $client->p2p_advertiser_payment_methods;
    is scalar(
        grep { $existing->{$_}{fields}{instructions} eq 'contact me?' && $existing->{$_}{method} =~ /^(paypal|bank_transfer)$/ }
            keys %$existing
        ),
        0, "None of the pm entries was created for client although only one of them is a duplicate";

    is exception {
        $client->p2p_advertiser_payment_methods(
            create => [{
                    method  => 'paypal',
                    account => '1234'
                },
                {
                    method    => 'bank_transfer',
                    account   => 'hsbc345',
                    bank_name => 'HSBC'
                }])
    }, undef, "not a duplicate when required field: account is different";

    $client2 = BOM::Test::Helper::P2PWithClient::create_advertiser(
        balance        => 20,
        client_details => {residence => 'id'});

    cmp_deeply(
        exception {
            $client2->p2p_advertiser_payment_methods(
                create => [{
                        method       => 'paypal',
                        account      => '123',
                        instructions => 'contact me?'
                    },
                    {
                        method       => 'bank_transfer',
                        account      => '123xx',
                        bank_name    => 'HSBC',
                        instructions => 'contact me?'
                    }])
        },
        {
            error_code     => 'PaymentMethodInfoAlreadyInUse',
            message_params => ['PayPal']
        },
        "pm create failed because duplicate match found for client2's paypal with client1's paypal"
    );

    $existing = $client2->p2p_advertiser_payment_methods;
    is scalar(
        grep { $existing->{$_}{fields}{instructions} eq 'contact me?' && $existing->{$_}{method} =~ /^(paypal|bank_transfer)$/ }
            keys %$existing
        ),
        0, "None of the pm entries was created for client2 although only one of them is a duplicate";

    is exception {
        $client2->p2p_advertiser_payment_methods(
            create => [{
                    method  => 'paypal',
                    account => '1235'
                },
                {
                    method    => 'bank_transfer',
                    account   => '123xx',
                    bank_name => 'HSBC'
                }])
    }, undef, "not a duplicate when one/more required fields are different";

    cmp_deeply(
        exception {
            $client2->p2p_advertiser_payment_methods(
                create => [{
                        method       => 'paypal',
                        account      => '129',
                        instructions => 'contact me?'
                    },
                    {
                        method       => 'paypal',
                        account      => '129',
                        instructions => 'contact me?'
                    }])
        },
        {
            error_code     => 'DuplicatePaymentMethod',
            message_params => ['PayPal']
        },
        "pm create failed because duplicate match found within array entries for client2's pm create"
    );

    $existing = $client->p2p_advertiser_payment_methods;
    is scalar(grep { $existing->{$_}{method} eq 'paypal' && $existing->{$_}{fields}{instructions} eq 'contact me?' } keys %$existing), 0,
        "None of the pm entries was created for client2";
};

subtest 'update' => sub {
    my $existing = $client->p2p_advertiser_payment_methods;
    my ($id) = grep { $existing->{$_}{method} eq 'btc_smega' } keys %$existing;
    $runtime_config->payment_methods_enabled(0);

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(update => {$id => {is_enabled => 1}}) },
        {
            error_code => 'PaymentMethodsDisabled',
        },
        'pm feature disabled'
    );

    $runtime_config->payment_methods_enabled(1);

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(update => {-1 => {is_enabled => 1}}) },
        {error_code => 'PaymentMethodNotFound'},
        'Invalid method id'
    );

    @emitted_events = ();
    ok $client->p2p_advertiser_payment_methods(update => {$id => {is_enabled => 1}})->{$id}{is_enabled}, 'enable a method';
    cmp_deeply \@emitted_events, [['p2p_adverts_updated', {'advertiser_id' => $advertiser->{id}}]], 'advert update event fired';

    cmp_deeply(
        exception { $client->p2p_advertiser_payment_methods(update => {$id => {code => 'x'}}) },
        {
            error_code     => 'InvalidPaymentMethodField',
            message_params => ['code', 'BTC SMEGA']
        },
        'Invalid field'
    );

    cmp_deeply(
        exception {
            $client->p2p_advertiser_payment_methods(update => {$id => {account => ' '}})
        },
        {
            error_code     => 'MissingPaymentMethodField',
            message_params => ['BTC SMEGA account', 'BTC SMEGA']
        },
        'required field should not be empty'
    );

    cmp_deeply(
        $client->p2p_advertiser_payment_methods(
            update => {
                $id => {
                    account      => '457',
                    instructions => 'please pay now!'
                }}
        )->{$id},
        {
            method       => 'btc_smega',
            type         => 'ewallet',
            display_name => 'BTC SMEGA',
            is_enabled   => bool(1),
            fields       => {
                account => {
                    value        => '457',
                    display_name => 'BTC SMEGA account',
                    type         => 'text',
                    required     => bool(1)
                },
                instructions => {
                    value        => 'please pay now!',
                    display_name => 'Instructions',
                    type         => 'memo',
                    required     => bool(0),
                }
            },
            used_by_adverts => undef,
            used_by_orders  => undef,
        },
        'update a field and add another'
    );

    $pm_country_config->{btc_smega}{mode} = 'include';
    $runtime_config->payment_method_countries($json->encode($pm_country_config));

    is $client->p2p_advertiser_payment_methods(update => {$id => {account => '456'}})->{$id}{fields}{account}{value}, '456',
        'can update method disabled in country';

    $pm_country_config->{btc_smega}{mode} = 'exclude';
    $runtime_config->payment_method_countries($json->encode($pm_country_config));

    my $existing_adv2 = $client2->p2p_advertiser_payment_methods;

    my ($id_paypal) = grep { $existing_adv2->{$_}{method} eq 'paypal' } keys %$existing_adv2;
    my ($id_bt)     = grep { $existing_adv2->{$_}{method} eq 'bank_transfer' } keys %$existing_adv2;

    cmp_deeply(
        exception { $client2->p2p_advertiser_payment_methods(update => {$id_paypal => {account => '1234'}, $id_bt => {account => '1234'}}) },
        {
            error_code     => 'PaymentMethodInfoAlreadyInUse',
            message_params => ['PayPal']
        },
        "No pm update for client2 since one of his update entries has a duplicate match with client1's paypal."
    );

    $existing = $client2->p2p_advertiser_payment_methods;
    is scalar(grep { $existing->{$_}{fields}{account} eq '1234' } keys %$existing), 0, "None of the pm entries was updated for client2";

    cmp_deeply(
        exception { $client2->p2p_advertiser_payment_methods(update => {$id_paypal => {account => 'hsbc345'}, $id_bt => {account => 'hsbc345'}}) },
        {
            error_code     => 'PaymentMethodInfoAlreadyInUse',
            message_params => ['Bank Transfer']
        },
        "No pm update for client2 since one of his update entries has a duplicate match with client1's bank_transfer."
    );

    $existing = $client2->p2p_advertiser_payment_methods;
    is scalar(grep { $existing->{$_}{fields}{account} eq 'hsbc345' } keys %$existing), 0, "None of the pm entries was updated for client2";

    is exception {
        $client2->p2p_advertiser_payment_methods(
            update => {
                $id_paypal => {account => '1236'},
                $id_bt     => {
                    account   => '123xx',
                    bank_name => 'required'
                }})
    },
        undef,
        "Successful pm update for client2 since none of his update entries has duplicate match with client1's bank_transfer due to difference in another required field: bank_name";

    my $updated_pm_list = $client2->p2p_advertiser_payment_methods(create => [{method => 'paypal', account => '1299'}]);
    my ($id1, $id2) = grep { $updated_pm_list->{$_}{method} eq 'paypal' } keys %$updated_pm_list;

    cmp_deeply(
        exception {
            $client2->p2p_advertiser_payment_methods(
                update => {
                    $id1 => {account => '1200'},
                    $id2 => {account => '1200'}})
        },
        {
            error_code     => 'DuplicatePaymentMethod',
            message_params => ['PayPal']
        },
        "Duplicate match found within array entries for client2's pm update. Hence, none of the pm entries will be updated for client2"
    );

    $existing = $client2->p2p_advertiser_payment_methods;
    is scalar(grep { $existing->{$_}{fields}{account} eq '1200' } keys %$existing), 0, "None of the pm entries was updated for client2";
};

subtest 'delete' => sub {

    $client3 = BOM::Test::Helper::P2PWithClient::create_advertiser(
        balance        => 40,
        client_details => {residence => 'za'});

    my $existing = $client3->p2p_advertiser_payment_methods(
        create => [{
                method  => 'btc_smega',
                account => '1xx'
            },
            {
                method    => 'bank_transfer',
                account   => '12abx',
                bank_name => 'CIMB'
            },
            {
                method    => 'bank_transfer',
                account   => '12aby',
                bank_name => 'CIMB'
            }]);

    my ($id) = grep { $existing->{$_}{method} eq 'btc_smega' } keys %$existing;

    $runtime_config->payment_methods_enabled(0);

    cmp_deeply(
        exception { $client3->p2p_advertiser_payment_methods(delete => [$id]) },
        {
            error_code => 'PaymentMethodsDisabled',
        },
        'pm feature disabled'
    );

    $runtime_config->payment_methods_enabled(1);

    cmp_deeply(exception { $client3->p2p_advertiser_payment_methods(delete => [-1]) }, {error_code => 'PaymentMethodNotFound'}, 'Invalid method id');

    @emitted_events = ();
    is $client3->p2p_advertiser_payment_methods(delete => [$id])->{$id}, undef, 'delete ok';
    cmp_deeply \@emitted_events, [['p2p_adverts_updated', {'advertiser_id' => $client3->p2p_advertiser_info()->{id}}]], 'advert update event fired';

    my @ids = keys $client3->p2p_advertiser_payment_methods->%*;
    cmp_deeply($client3->p2p_advertiser_payment_methods(delete => \@ids), {}, 'delete everything');

};

subtest 'combo operations' => sub {

    my $existing = $client3->p2p_advertiser_payment_methods(
        create => [{
                method  => 'btc_smega',
                account => '1xx'
            }]);

    my ($id) = grep { $existing->{$_}{method} eq 'btc_smega' } keys %$existing;

    cmp_deeply(
        exception { $client3->p2p_advertiser_payment_methods(delete => [$id], update => {$id => {account => '2xx'}}) },
        {error_code => 'PaymentMethodNotFound'},
        'Delete followed by update of the same pm id is not allowed'
    );

    $existing = $client3->p2p_advertiser_payment_methods(
        create => [{
                method  => 'btc_smega',
                account => '1xx'
            }]);

    ($id) = grep { $existing->{$_}{method} eq 'btc_smega' } keys %$existing;

    cmp_deeply(
        exception {
            $client3->p2p_advertiser_payment_methods(
                update => {$id => {account => '2xx'}},
                create => [{
                        method  => 'btc_smega',
                        account => '2xx'
                    }])
        },
        {
            error_code     => 'DuplicatePaymentMethod',
            message_params => ['BTC SMEGA']
        },
        'Update followed by create of the same pm details is not allowed'
    );

};

subtest 'scenario when optional field becomes required and vice versa' => sub {

    my $existing = $client3->p2p_advertiser_payment_methods(
        create => [{
                method    => 'bank_transfer',
                account   => '1xx',
                bank_name => 'MAYBANK'
            }]);

    my ($id) = grep { $existing->{$_}{method} eq 'bank_transfer' } keys %$existing;

    is exception { $client3->p2p_advertiser_payment_methods(update => {$id => {account => '2xx', bank_code => ''}}) }, undef,
        'bank_code field can be empty when it becomes optional';

    delete $pm_config->{bank_transfer}{fields}{bank_code}{required};
    $mock_config->mock('p2p_payment_methods' => $pm_config);

    cmp_deeply(
        exception { $client3->p2p_advertiser_payment_methods(update => {$id => {account => '1xx'}}) },
        {
            error_code     => 'MissingPaymentMethodField',
            message_params => ['SWIFT or IFSC code', 'Bank Transfer']
        },
        'cannot update when required field is missing'
    );

    is exception { $client3->p2p_advertiser_payment_methods(update => {$id => {account => '2xx', bank_code => 'fsaf'}}) }, undef,
        'update successful when all required fields are present';

    $pm_config->{bank_transfer}{fields}{bank_name}{required} = 0;
    $mock_config->mock('p2p_payment_methods' => $pm_config);

    cmp_deeply(exception { $client3->p2p_advertiser_payment_methods(update => {$id => {bank_name => ''}}) },
        undef, 'bank_name field can be empty when it becomes optional');

    $pm_config->{bank_transfer}{fields}{bank_code}{required} = 0;
    delete $pm_config->{bank_transfer}{fields}{bank_name}{required};
    $mock_config->mock('p2p_payment_methods' => $pm_config);
};

subtest 'validation for Other payment method' => sub {

    foreach my $name ("btcsmega##", "btc1234smega", "use btcsmega to pay") {
        cmp_deeply(
            exception {
                $client3->p2p_advertiser_payment_methods(
                    create => [{
                            method  => 'other',
                            account => '1xx2',
                            name    => $name
                        }])
            },
            {
                error_code     => 'InvalidOtherPaymentMethodName',
                message_params => [$name]
            },
            "cannot create Other pm with name: $name that's too similar with an existing P2P payment method supported in advertiser's country"
        );
    }

    $pm_country_config->{btc_smega} = {
        mode      => 'exclude',
        countries => ['za']};
    $pm_country_config->{bank_transfer} = {
        mode      => 'exclude',
        countries => ['za']};
    $runtime_config->payment_method_countries($json->encode($pm_country_config));

    foreach my $name ("btc##smega", "btcsmegani", "pay with btcsmega") {
        is(
            exception {
                $client3->p2p_advertiser_payment_methods(
                    create => [{
                            method  => 'other',
                            account => '122xx',
                            name    => $name
                        }])
            },
            undef,
            "can create Other pm with name: $name that's too similar with an existing P2P payment method if it's not supported in advertiser's country"
        );
    }

    $pm_country_config->{btc_smega} = {
        mode      => 'include',
        countries => ['za']};
    $runtime_config->payment_method_countries($json->encode($pm_country_config));

    my $existing = $client3->p2p_advertiser_payment_methods();
    my ($id) = grep { $existing->{$_}{method} eq 'other' && $existing->{$_}{fields}{name}{value} eq 'btcsmegani' } keys %$existing;

    cmp_deeply(
        exception { $client3->p2p_advertiser_payment_methods(update => {$id => {account => '122xxy'}}) },
        {
            error_code     => 'InvalidOtherPaymentMethodName',
            message_params => ['btcsmegani']
        },
        "cannot update Other pm with existing name that's too similar with an existing P2P payment method supported in advertiser's country"
    );

    is exception { $client3->p2p_advertiser_payment_methods(update => {$id => {account => '122xxy', name => 'smeguni'}}) }, undef,
        "can update if existing name field is updated to a name that's not too similar with an existing P2P payment method supported in advertiser's country";
};

done_testing();
