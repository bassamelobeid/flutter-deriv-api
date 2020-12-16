use Test::Most;
use BOM::User::Record::Payment;
use Date::Utility;
use BOM::Config::Runtime;

use Test::MockModule;

subtest 'BOM::User::Record::Payment validations' => sub {
    subtest 'when user_id is missing' => sub {
        my $payment = BOM::User::Record::Payment->new(
            payment_type       => 'CreditCard',
            account_identifier => 'XXXXXX********01'
        );

        is($payment->save(), 0, '->save() returns 0');

        is($payment->get_distinct_payment_accounts_for_time_period(period => 30), 0, '->get_distinct_payment_accounts_for_time_period() returns 0');
    };

    subtest 'when payment_type is missing' => sub {
        my $payment = BOM::User::Record::Payment->new(
            user_id            => 1,
            account_identifier => 'XXXXXX********01'
        );

        is($payment->save(), 0, '->save() returns 0');

        is($payment->get_distinct_payment_accounts_for_time_period(period => 30), 0, '->get_distinct_payment_accounts_for_time_period() returns 0');
    };

    subtest 'when account_identifier is missing' => sub {
        my $payment = BOM::User::Record::Payment->new(
            user_id      => 1,
            payment_type => 'CreditCard',
        );

        is($payment->save(), 0, '->save() returns 0');

        is($payment->get_distinct_payment_accounts_for_time_period(period => 30), 0, '->get_distinct_payment_accounts_for_time_period() returns 0');
    };
};

subtest 'save & get_distinct_payment_accounts_for_time_period' => sub {
    my $USER_ID_1   = 1;
    my $payment_101 = BOM::User::Record::Payment->new(
        user_id            => $USER_ID_1,
        payment_type       => 'CreditCard',
        account_identifier => 'XXXXXX********01'
    );

    is($payment_101->save(), 1, 'payment saved with account identifier = ' . $payment_101->account_identifier());

    is($payment_101->get_distinct_payment_accounts_for_time_period(period => 1), 1, 'counts only one unique account');

    my $payment_102 = BOM::User::Record::Payment->new(
        user_id            => $USER_ID_1,
        payment_type       => 'CreditCard',
        account_identifier => 'XXXXXX********02'
    );

    is($payment_102->save(), 1, 'payment saved with account identifier = ' . $payment_102->account_identifier());

    is($payment_102->get_distinct_payment_accounts_for_time_period(period => 1), 2, 'counts two unique accounts');

    my $USER_ID_2   = 2;
    my $payment_201 = BOM::User::Record::Payment->new(
        user_id            => $USER_ID_2,
        payment_type       => 'CreditCard',
        account_identifier => 'XXXXXX********01'
    );

    is($payment_201->save(), 1, 'payment saved with account identifier = ' . $payment_201->account_identifier() . ' for a new user');

    is($payment_201->get_distinct_payment_accounts_for_time_period(period => 1), 1, 'counts only one unique account');
};

# a few test for private subs

subtest '_build_storage_key' => sub {
    my $today = Date::Utility->new;
    is(BOM::User::Record::Payment::_build_storage_key(), 0, 'returns 0 if user_id is missing');
    is(BOM::User::Record::Payment::_build_storage_key(user_id => 123), 'PAYMENT_RECORD::UID::123::' . $today->date_yyyymmdd, 'returns correct key');
    is(
        BOM::User::Record::Payment::_build_storage_key(
            user_id     => 123,
            days_behind => 0
        ),
        'PAYMENT_RECORD::UID::123::' . $today->date_yyyymmdd,
        'returns correct key'
    );
    is(
        BOM::User::Record::Payment::_build_storage_key(
            user_id     => 123,
            days_behind => 1
        ),
        'PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('1d')->date_yyyymmdd,
        'returns correct key'
    );
};

subtest '_get_keys_for_time_period' => sub {
    my $today = Date::Utility->new;

    # all values should be treated as 1
    for my $period (undef, 0, 1) {
        cmp_bag(
            BOM::User::Record::Payment::_get_keys_for_time_period(
                user_id => 123,
                period  => $period
            ),
            ['PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('0d')->date_yyyymmdd]);
    }

    my @expected_keys = (
        'PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('0d')->date_yyyymmdd,
        'PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('1d')->date_yyyymmdd,
        'PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('2d')->date_yyyymmdd,
        'PAYMENT_RECORD::UID::123::' . $today->minus_time_interval('3d')->date_yyyymmdd,
    );

    cmp_bag(
        BOM::User::Record::Payment::_get_keys_for_time_period(
            user_id => 123,
            period  => 4
        ),
        \@expected_keys
    );
};

done_testing;
