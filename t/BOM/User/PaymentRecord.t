use Test::Most;

use Data::Dump 'pp';
use Date::Utility;
use Test::Fatal;
use Test::MockModule;

use BOM::Config::Runtime;
use BOM::User::PaymentRecord;

subtest 'BOM::User::PaymentRecord::new' => sub {
    subtest 'when user_id is missing' => sub {
        like(exception { BOM::User::PaymentRecord->new() }, qr/user_id is mandatory/, 'dies with the right error message');
    };
};

subtest 'BOM::User::PaymentRecord::add_payment' => sub {
    subtest 'when payment_type is missing' => sub {
        my $record = BOM::User::PaymentRecord->new(user_id => 1);

        is($record->add_payment(account_identifier => 'XXXXXX********01'), 0, 'does not save the payment');
    };

    subtest 'when account_identifier is missing' => sub {
        my $record = BOM::User::PaymentRecord->new(user_id => 1);

        is($record->add_payment(payment_type => 'CreditCard'), 0, 'does not save the payment');
    };
};

subtest 'BOM::User::PaymentRecord::get_distinct_payment_accounts_for_time_period' => sub {
    subtest 'when the client does not has recorded payments' => sub {
        my $record = BOM::User::PaymentRecord->new(user_id => 1);
        is($record->get_distinct_payment_accounts_for_time_period(period => 30), 0, 'returns 0');
    };

    subtest 'when the client has made 1 deposit' => sub {
        my $record = BOM::User::PaymentRecord->new(user_id => 2);

        is(
            $record->add_payment(
                payment_type       => 'CreditCard',
                account_identifier => 'XXXXXX********01'
            ),
            1,
            'a new payment has been added'
        );

        is($record->get_distinct_payment_accounts_for_time_period(period => 30), 1, 'counts one used payment account');
    };

    subtest 'when the client has made 2 deposits' => sub {
        my $record = BOM::User::PaymentRecord->new(user_id => 3);

        is(
            $record->add_payment(
                payment_type       => 'CreditCard',
                account_identifier => 'XXXXXX********01'
            ),
            1,
            'a new payment has been added'
        );

        is(
            $record->add_payment(
                payment_type       => 'CreditCard',
                account_identifier => 'XXXXXX********02'
            ),
            1,
            'a new payment has been added'
        );

        is($record->get_distinct_payment_accounts_for_time_period(period => 30), 2, 'counts two used payment account');
    }
};

subtest 'BOM::User::PaymentRecord::set_flag/is_flagged' => sub {
    subtest 'when the flag has not been set' => sub {
        my $record = BOM::User::PaymentRecord->new(user_id => 1);
        is($record->is_flagged('dummy'), 0, 'is_flagged returns 0');
    };

    subtest 'when the flag has been set' => sub {
        my $record = BOM::User::PaymentRecord->new(user_id => 1);
        $record->set_flag(name => 'dummy');
        is($record->is_flagged('dummy'), 1, 'is_flagged returns 1');
    };
};

# a few test for private subs
subtest 'BOM::User::PaymentRecord::_build_storage_key' => sub {
    my $today = Date::Utility->new;
    is(BOM::User::PaymentRecord::_build_storage_key(), 0, 'returns 0 if user_id is missing');
    is(BOM::User::PaymentRecord::_build_storage_key(user_id => 123), 'PAYMENT_RECORD::UID::123::' . $today->date_yyyymmdd, 'returns correct key');
    is(
        BOM::User::PaymentRecord::_build_storage_key(
            user_id     => 123,
            days_behind => 0
        ),
        'PAYMENT_RECORD::UID::123::' . $today->date_yyyymmdd,
        'returns correct key'
    );
    is(
        BOM::User::PaymentRecord::_build_storage_key(
            user_id     => 123,
            days_behind => 1
        ),
        'PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('1d')->date_yyyymmdd,
        'returns correct key'
    );
};

subtest 'BOM::User::PaymentRecord::_get_keys_for_time_period' => sub {
    my $today = Date::Utility->new;

    # all values should be treated as 1
    for my $period (undef, 0, 1) {
        cmp_bag(
            BOM::User::PaymentRecord::_get_keys_for_time_period(
                user_id => 123,
                period  => $period
            ),
            ['PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('0d')->date_yyyymmdd],
            sprintf('encodes correctly for (period => %s) as only one key, today', pp($period)));
    }

    my @expected_keys = (
        'PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('0d')->date_yyyymmdd,
        'PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('1d')->date_yyyymmdd,
        'PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('2d')->date_yyyymmdd,
        'PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('3d')->date_yyyymmdd,
    );

    cmp_bag(
        BOM::User::PaymentRecord::_get_keys_for_time_period(
            user_id => 123,
            period  => 4
        ),
        \@expected_keys,
        'encodes correctly for (period => 4)'
    );
};

done_testing;
