use Test::Most;
use Date::Utility;
use Test::Fatal;
use Test::MockModule;
use Test::Deep;
use Test::MockTime qw/restore_time set_fixed_time/;
use Digest::SHA qw/sha256_hex/;

use BOM::Config::Runtime;
use BOM::User::PaymentRecord;

my $fields  = +BOM::User::PaymentRecord::PAYMENT_SERIALIZE_FIELDS;
my $mock_pr = Test::MockModule->new('BOM::User::PaymentRecord');

$mock_pr->mock(
    'PAYMENT_SERIALIZE_FIELDS',
    sub {
        return $fields;
    });

my $pr;

subtest 'BOM::User::PaymentRecord::new' => sub {
    subtest 'when user_id is missing' => sub {
        like(exception { BOM::User::PaymentRecord->new() }, qr/user_id is mandatory/, 'dies with the right error message');
    };
};

subtest 'instantiate a valid object' => sub {
    $pr = BOM::User::PaymentRecord->new(user_id => 1000);

    isa_ok $pr, 'BOM::User::PaymentRecord', 'We got the expected instance';
};

subtest 'storage key' => sub {
    is $pr->storage_key, 'PAYMENT_RECORD_V2::UID::1000', 'Expected storage key';
};

subtest 'payloads' => sub {
    my $payment = {
        pp => 'Test',
        pm => 'Capy',
        pt => 'Bara',
        id => '1900**9000'
    };

    my $payload;

    subtest 'complete args' => sub {
        $payload = 'Test|Capy|Bara|1900**9000';
        is $pr->get_payload($payment),          $payload, 'Expected payload on a fully filled payment';
        cmp_deeply $pr->from_payload($payload), $payment, 'Expected payment from payload';
    };

    $payment->{pt} = undef;

    subtest 'payment type is undef' => sub {
        $payload = 'Test|Capy|^|1900**9000';
        is $pr->get_payload($payment),          $payload, 'Expected payload';
        cmp_deeply $pr->from_payload($payload), $payment, 'Expected payment from payload';
    };

    delete $payment->{pt};

    subtest 'payment type was deleted' => sub {
        $payload = 'Test|Capy|^|1900**9000';
        is $pr->get_payload($payment),          $payload, 'Expected payload';
        cmp_deeply $pr->from_payload($payload), $payment, 'Expected payment from payload';
    };

    $payment->{pt} = '';

    subtest 'payment type is empty string' => sub {
        $payload = 'Test|Capy||1900**9000';
        is $pr->get_payload($payment),          $payload, 'Expected payload';
        cmp_deeply $pr->from_payload($payload), $payment, 'Expected payment from payload';
    };

    subtest 'the edgest of cases' => sub {
        # when the serializable array size > the payload split array, we will get filled by undefs
        # even though there are no undef symbols `^`, me thinks this is the correct behaviour
        # as the array chunks are not present, although debatable.
        $payload = '';
        cmp_deeply $pr->from_payload($payload),
            {
            pp => undef,
            pm => undef,
            pt => undef,
            id => undef,
            },
            'payment on the edge!';

        # to illustrate the point above, watch this example...
        $payload = 'capy|bara|^';
        cmp_deeply $pr->from_payload($payload),
            {
            pp => 'capy',
            pm => 'bara',
            pt => undef,
            id => undef,
            },
            'payment on the edge!';

        # so if we ever add a new serializable field, the old entries will get filled by undefs
        # this makes more sense now, innit?

        push $fields->@*, 'new_shiny_field';

        $payload = 'capy|bara|test|9000';
        cmp_deeply $pr->from_payload($payload),
            {
            pp              => 'capy',
            pm              => 'bara',
            pt              => 'test',
            id              => '9000',
            new_shiny_field => undef,
            },
            'payment on the edge!';

        pop $fields->@*;    # come back to normal
    };
};

subtest 'redis storage' => sub {
    my $time = time;

    my $payment = {
        pp => 'Test',
        pm => 'Capy',
        pt => 'Bara',
        id => '1900**9000'
    };

    subtest 'store some payments' => sub {
        ok $pr->add_payment($payment->%*);

        set_fixed_time($time - 86400);

        ok $pr->add_payment($payment->%*, pt => 'CreditCard'), 'add payment';

        ok $pr->add_payment($payment->%*, pt => 'CreditCard'), 'add payment (repeated info is not duplicated on a zset)';

        ok $pr->add_payment($payment->%*, pt => 'CreditXard'), 'add payment';
        ok $pr->add_payment($payment->%*, pt => 'APM'),        'add payment';

        set_fixed_time($time - 86400 * 2);

        ok $pr->add_payment($payment->%*, pp => 'Beta'),  'add payment';
        ok $pr->add_payment($payment->%*, pp => 'Theta'), 'add payment';

        set_fixed_time($time - 86400 * 3);

        ok $pr->add_payment($payment->%*, pm => 'Alpha'), 'add payment';

        ok $pr->add_payment(
            $payment->%*,
            pp => 'Theta',
            id => '9009::8008'
            ),
            'add payment';

        subtest 'retrieve payments' => sub {
            set_fixed_time($time);
            cmp_deeply $pr->get_payments(0), [], 'Zero payments';
            cmp_deeply $pr->get_payments(1 + BOM::User::PaymentRecord::LIFETIME_IN_DAYS), [], 'Gone too far away';

            cmp_bag $pr->get_payments(BOM::User::PaymentRecord::LIFETIME_IN_DAYS),
                [{
                    pm => 'Alpha',
                    pp => 'Test',
                    id => '1900**9000',
                    pt => 'Bara'
                },
                {
                    pt => 'Bara',
                    id => '9009::8008',
                    pp => 'Theta',
                    pm => 'Capy'
                },
                {
                    id => '1900**9000',
                    pt => 'Bara',
                    pm => 'Capy',
                    pp => 'Beta'
                },
                {
                    pp => 'Theta',
                    pm => 'Capy',
                    id => '1900**9000',
                    pt => 'Bara'
                },
                {
                    pt => 'APM',
                    id => '1900**9000',
                    pm => 'Capy',
                    pp => 'Test'
                },
                {
                    pm => 'Capy',
                    pp => 'Test',
                    id => '1900**9000',
                    pt => 'CreditCard'
                },
                {
                    pp => 'Test',
                    pm => 'Capy',
                    pt => 'CreditXard',
                    id => '1900**9000'
                },
                {
                    pm => 'Capy',
                    pp => 'Test',
                    id => '1900**9000',
                    pt => 'Bara'
                }
                ],
                'Got all the payments';

            cmp_bag $pr->get_payments(1),
                [+{$payment->%*, pt => 'APM'}, +{$payment->%*, pt => 'CreditCard'}, +{$payment->%*, pt => 'CreditXard'}, $payment,],
                'Got all the payments (1 day ago)';

            cmp_bag $pr->get_payments(2),
                [
                +{$payment->%*, pp => 'Theta'},
                +{$payment->%*, pp => 'Beta'},
                +{$payment->%*, pt => 'APM'},
                +{$payment->%*, pt => 'CreditCard'},
                +{$payment->%*, pt => 'CreditXard'},
                $payment,
                ],
                'Got all the payments (2 days ago)';

            cmp_bag $pr->get_payments(3),
                [
                +{
                    $payment->%*,
                    pp => 'Theta',
                    id => '9009::8008'
                },
                +{$payment->%*, pm => 'Alpha'},
                +{$payment->%*, pp => 'Theta'},
                +{$payment->%*, pp => 'Beta'},
                +{$payment->%*, pt => 'APM'},
                +{$payment->%*, pt => 'CreditCard'},
                +{$payment->%*, pt => 'CreditXard'},
                $payment,
                ],
                'Got all the payments (3 days ago)';

            subtest 'filtering' => sub {
                my $redis = BOM::User::PaymentRecord::_get_redis();

                ok $pr->add_payment(
                    $payment->%*,
                    pm => undef,
                    id => undef
                    ),
                    'add payment';

                my $records = $redis->zrangebyscore($pr->storage_key, '-Inf', '+Inf');

                cmp_bag $pr->filter_payments({}, $records),
                    [
                    'Test|^|Bara|^',                   'Beta|Capy|Bara|1900**9000',
                    'Test|Alpha|Bara|1900**9000',      'Test|Capy|APM|1900**9000',
                    'Test|Capy|Bara|1900**9000',       'Test|Capy|CreditCard|1900**9000',
                    'Test|Capy|CreditXard|1900**9000', 'Theta|Capy|Bara|1900**9000',
                    'Theta|Capy|Bara|9009::8008'
                    ],
                    'Did not filter anything';

                cmp_bag $pr->filter_payments({
                        pm => undef,
                        id => undef,
                    },
                    $records
                    ),
                    ['Test|^|Bara|^',],
                    'Filter the undef';

                cmp_bag $pr->filter_payments({pp => 'Test'}, $records),
                    [
                    'Test|Alpha|Bara|1900**9000',      'Test|Capy|APM|1900**9000',
                    'Test|Capy|Bara|1900**9000',       'Test|Capy|CreditCard|1900**9000',
                    'Test|Capy|CreditXard|1900**9000', 'Test|^|Bara|^',
                    ],
                    'pp=Test';

                cmp_bag $pr->filter_payments({
                        pp => 'Test',
                        pt => 'Bara'
                    },
                    $records
                    ),
                    ['Test|^|Bara|^', 'Test|Alpha|Bara|1900**9000', 'Test|Capy|Bara|1900**9000',], 'pp=Test pt=Bara';

                cmp_bag $pr->filter_payments({
                        id => '9009::8008',
                    },
                    $records
                    ),
                    ['Theta|Capy|Bara|9009::8008'], 'id=9009::8008';

                cmp_bag $pr->filter_payments({
                        id => '1900**9000',
                        pt => 'CreditCard',
                        pm => 'Capy',
                        pp => 'Test',
                    },
                    $records
                    ),
                    ['Test|Capy|CreditCard|1900**9000',], 'full id';

                cmp_bag $pr->filter_payments({
                        id => '1900**9001',
                        pt => 'CreditCard',
                        pm => 'Capy',
                        pp => 'Test',
                    },
                    $records
                    ),
                    [], 'full id (empty)';
            };

            subtest 'trimmer' => sub {
                ok BOM::User::PaymentRecord::trimmer();

                my $redis = BOM::User::PaymentRecord::_get_redis();

                is scalar $redis->zrangebyscore($pr->storage_key, '-Inf', '+Inf')->@*, 9, 'No records were deleted';

                set_fixed_time($time + 86400 * 87);    # jump 87 days into the future

                ok BOM::User::PaymentRecord::trimmer();

                is scalar $redis->zrangebyscore($pr->storage_key, '-Inf', '+Inf')->@*, 7, 'Records added 3 days (relative) ago were trimmed';

                set_fixed_time($time + 86400 * 88);    # jump 88 days into the future

                ok BOM::User::PaymentRecord::trimmer();

                is scalar $redis->zrangebyscore($pr->storage_key, '-Inf', '+Inf')->@*, 5, 'Records added 2 days (relative) ago were trimmed';

                set_fixed_time($time + 86400 * 89);    # jump 89 days into the future

                ok BOM::User::PaymentRecord::trimmer();

                is scalar $redis->zrangebyscore($pr->storage_key, '-Inf', '+Inf')->@*, 2, 'Records added yesterday (relative) ago were trimmed';

                set_fixed_time($time + 86400 * 90);    # jump 90 days into the future

                ok BOM::User::PaymentRecord::trimmer();

                is scalar $redis->zrangebyscore($pr->storage_key, '-Inf', '+Inf')->@*, 0, 'All records should have been trimmed';
            };
        };
    };
};

# the following will test the deprecated parts of the package and thus a removal is due somewhere
# in the future

subtest 'deprecated' => sub {
    is $pr->get_distinct_payment_accounts_for_time_period(), 0, 'No period passed';
    is $pr->get_distinct_payment_accounts_for_time_period(period => 10), 0, 'No payment type passed';

    dies_ok {
        $pr->get_distinct_payment_accounts_for_time_period(
            period       => 10000,
            payment_type => 'Bara'
        );
    }
    'Period is too large';

    add_legacy_payment(
        id      => 1000,
        user_id => $pr->{user_id},
        pt      => 'CreditCard',
    );

    is $pr->get_distinct_payment_accounts_for_time_period(
        period       => 10,
        payment_type => 'CreditCard'
        ),
        1, '1 record found';

    add_legacy_payment(
        id      => 1000,
        user_id => $pr->{user_id},
        pt      => 'CreditCard',
    );

    is $pr->get_distinct_payment_accounts_for_time_period(
        period       => 10,
        payment_type => 'CreditCard'
        ),
        1, '1 record found still';

    add_legacy_payment(
        id      => 2000,
        user_id => $pr->{user_id},
        pt      => 'CreditCard',
    );

    is $pr->get_distinct_payment_accounts_for_time_period(
        period       => 10,
        payment_type => 'CreditCard'
        ),
        2, '2 records found';

    is $pr->get_distinct_payment_accounts_for_time_period(
        period       => 10,
        payment_type => 'Bara'
        ),
        0, '0 records found';
    add_legacy_payment(
        id      => 2000,
        user_id => $pr->{user_id},
        pt      => 'Bara',
    );

    is $pr->get_distinct_payment_accounts_for_time_period(
        period       => 10,
        payment_type => 'Bara'
        ),
        1, '1 record found';

    add_legacy_payment(
        id      => 2000,
        user_id => $pr->{user_id} + 1,
        pt      => 'Capy',
    );
    is $pr->get_distinct_payment_accounts_for_time_period(
        period       => 10,
        payment_type => 'Capy'
        ),
        0, '0 record found';

    add_legacy_payment(
        id      => 2000,
        user_id => $pr->{user_id},
        pt      => 'Capy',
    );
    is $pr->get_distinct_payment_accounts_for_time_period(
        period       => 10,
        payment_type => 'Capy'
        ),
        1, '1 record found';

    subtest 'do not update the counter if there is a legacy clash for pt=CreditCard' => sub {
        ok $pr->add_payment(
            id      => 2000,
            user_id => $pr->{user_id},
            pt      => 'Capy',
        );
        ok !$pr->add_payment(
            id      => 2000,
            user_id => $pr->{user_id},
            pt      => 'CreditCard',
        );
        ok $pr->add_payment(
            id      => 2000,
            user_id => $pr->{user_id},
            pt      => 'Bara',
        );
        ok !$pr->add_payment(
            id      => 1000,
            user_id => $pr->{user_id},
            pt      => 'CreditCard',
        );
    };
};

subtest 'BOM::User::PaymentRecord::set_flag/is_flagged' => sub {
    subtest 'when the flag has not been set' => sub {
        my $record = BOM::User::PaymentRecord->new(
            user_id => 1,
        );
        is($record->is_flagged('dummy'), 0, 'is_flagged returns 0');
    };

    subtest 'when the flag has been set' => sub {
        my $record = BOM::User::PaymentRecord->new(
            user_id => 1,
        );
        set_legacy_flag(
            name    => 'dummy',
            user_id => 1
        );
        is($record->is_flagged('dummy'), 1, 'is_flagged returns 1');
    };
};

subtest '5 differents credit cards' => sub {
    $pr = BOM::User::PaymentRecord->new(user_id => 2000);

    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x01'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x02'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x03'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x04'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x05'
    );

    my $payments = $pr->get_raw_payments(10);

    cmp_bag $payments,
        [
        'bara|capy|CreditCard|0x01', 'bara|capy|CreditCard|0x02', 'bara|capy|CreditCard|0x03', 'bara|capy|CreditCard|0x04',
        'bara|capy|CreditCard|0x05'
        ],
        'expected payments';

    my $filtered = $pr->filter_payments({pt => 'CreditCard'}, $payments);
    cmp_bag $filtered,
        [
        'bara|capy|CreditCard|0x01', 'bara|capy|CreditCard|0x02', 'bara|capy|CreditCard|0x03', 'bara|capy|CreditCard|0x04',
        'bara|capy|CreditCard|0x05'
        ],
        'expected payments';

    my $grouped = $pr->group_by_id($filtered);

    cmp_bag $grouped,
        [
        'bara|capy|CreditCard|0x01', 'bara|capy|CreditCard|0x02', 'bara|capy|CreditCard|0x03', 'bara|capy|CreditCard|0x04',
        'bara|capy|CreditCard|0x05',
        ],
        'expected grouped payments';
};

subtest '5 differents credit cards (some CC repeated)' => sub {
    $pr = BOM::User::PaymentRecord->new(user_id => 2000);

    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x01'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x02'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x05'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x04'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x05'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x03'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x02'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x01'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x01'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x01'
    );

    my $payments = $pr->get_raw_payments(10);

    cmp_bag $payments,
        [
        'bara|capy|CreditCard|0x01', 'bara|capy|CreditCard|0x02', 'bara|capy|CreditCard|0x03', 'bara|capy|CreditCard|0x04',
        'bara|capy|CreditCard|0x05'
        ],
        'expected payments';

    my $filtered = $pr->filter_payments({pt => 'CreditCard'}, $payments);
    cmp_bag $filtered,
        [
        'bara|capy|CreditCard|0x01', 'bara|capy|CreditCard|0x02', 'bara|capy|CreditCard|0x03', 'bara|capy|CreditCard|0x04',
        'bara|capy|CreditCard|0x05'
        ],
        'expected payments';

    my $grouped = $pr->group_by_id($filtered);

    cmp_bag $grouped,
        [
        'bara|capy|CreditCard|0x01', 'bara|capy|CreditCard|0x02', 'bara|capy|CreditCard|0x03', 'bara|capy|CreditCard|0x04',
        'bara|capy|CreditCard|0x05',
        ],
        'expected grouped payments';
};
subtest '5 differents credit cards (different pm/pp)' => sub {
    $pr = BOM::User::PaymentRecord->new(user_id => 3000);

    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x01'
    );
    ok $pr->add_payment(
        pm => 'kapy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x01'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'tara',
        pt => 'CreditCard',
        id => '0x01'
    );

    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x02'
    );
    ok $pr->add_payment(
        pm => 'kapy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x02'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'tara',
        pt => 'CreditCard',
        id => '0x02'
    );

    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x03'
    );
    ok $pr->add_payment(
        pm => 'kapy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x03'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'tara',
        pt => 'CreditCard',
        id => '0x03'
    );

    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x04'
    );
    ok $pr->add_payment(
        pm => 'kapy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x04'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'tara',
        pt => 'CreditCard',
        id => '0x04'
    );

    ok $pr->add_payment(
        pm => 'capy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x05'
    );
    ok $pr->add_payment(
        pm => 'kapy',
        pp => 'bara',
        pt => 'CreditCard',
        id => '0x05'
    );
    ok $pr->add_payment(
        pm => 'capy',
        pp => 'tara',
        pt => 'CreditCard',
        id => '0x05'
    );

    my $payments = $pr->get_raw_payments(10);

    cmp_bag $payments,
        [
        'bara|capy|CreditCard|0x01', 'bara|capy|CreditCard|0x02', 'bara|capy|CreditCard|0x03', 'bara|capy|CreditCard|0x04',
        'bara|capy|CreditCard|0x05', 'bara|kapy|CreditCard|0x01', 'bara|kapy|CreditCard|0x02', 'bara|kapy|CreditCard|0x03',
        'bara|kapy|CreditCard|0x04', 'bara|kapy|CreditCard|0x05', 'tara|capy|CreditCard|0x01', 'tara|capy|CreditCard|0x02',
        'tara|capy|CreditCard|0x03', 'tara|capy|CreditCard|0x04', 'tara|capy|CreditCard|0x05'
        ],
        'expected payments';

    my $filtered = $pr->filter_payments({pt => 'CreditCard'}, $payments);
    cmp_bag $filtered,
        [
        'bara|capy|CreditCard|0x01', 'bara|capy|CreditCard|0x02', 'bara|capy|CreditCard|0x03', 'bara|capy|CreditCard|0x04',
        'bara|capy|CreditCard|0x05', 'bara|kapy|CreditCard|0x01', 'bara|kapy|CreditCard|0x02', 'bara|kapy|CreditCard|0x03',
        'bara|kapy|CreditCard|0x04', 'bara|kapy|CreditCard|0x05', 'tara|capy|CreditCard|0x01', 'tara|capy|CreditCard|0x02',
        'tara|capy|CreditCard|0x03', 'tara|capy|CreditCard|0x04', 'tara|capy|CreditCard|0x05'
        ],
        'expected payments';

    my $grouped = $pr->group_by_id($filtered);

    cmp_bag $grouped,
        [
        'bara|capy|CreditCard|0x01', 'bara|capy|CreditCard|0x02', 'bara|capy|CreditCard|0x03', 'bara|capy|CreditCard|0x04',
        'bara|capy|CreditCard|0x05',
        ],
        'expected grouped payments';
};

sub add_legacy_payment : method {
    my (%args) = @_;
    my $account_identifier = $args{id};

    return 0 unless $account_identifier;

    my $storage_key = BOM::User::PaymentRecord::_build_storage_key(
        user_id      => $args{user_id},
        payment_type => $args{pt});
    return 0 unless $storage_key;

    my $redis = BOM::User::PaymentRecord::_get_redis();
    $redis->multi;
    $redis->pfadd($storage_key, sha256_hex($account_identifier));
    # we set the expiry of the whole key
    # we extend expiry whenever the same key is updated
    $redis->expire($storage_key, 90);
    $redis->exec;

    return 1;
}

sub set_legacy_flag {
    my (%args)      = @_;
    my $flag_name   = $args{name}   // die 'name is mandatory';
    my $flag_expire = $args{expire} // 0;
    my $flag_key    = BOM::User::PaymentRecord::_build_flag_key(
        user_id => $args{user_id},
        name    => $flag_name
    );

    my $redis = BOM::User::PaymentRecord::_get_redis();
    $redis->multi;
    $redis->set($flag_key, 1);
    $redis->expire($flag_key, $flag_expire) if $flag_expire;
    $redis->exec;

    return 1;
}

restore_time();
done_testing();
