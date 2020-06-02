#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 12;
use Test::Exception;
use Test::Warnings;

use Date::Utility;
use BOM::Database::Model::Account;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::Payment::DoughFlow;
use BOM::Database::ClientDB;
use BOM::Database::Model::Constants;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $connection_builder;
my $account;
my $client;
my $payment_mapper;

lives_ok {

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client->set_default_account('USD');

}
'Create a client with no payment';

my $payment_data_mapper;

subtest 'get payments summary' => sub {
    lives_ok {
        $payment_data_mapper = BOM::Database::DataMapper::Payment->new({
                'client_loginid' => 'CR0111',
                'currency_code'  => 'USD',
            })
    }
    'Initializing payment data mapper for CR0111 USD';

    my $summary = $payment_data_mapper->get_summary();
    is scalar @$summary, 6, '6 items as expected of dml data';

    my $total =
        (grep { not defined $_->{action_type} and not defined $_->{payment_system} } @$summary)[0];

    is $total->{amount} + 0, -25, 'total of deposits and withdraws is as expected.';
};

subtest 'get total deposit & withdrawal' => sub {
    lives_ok {
        $payment_data_mapper = BOM::Database::DataMapper::Payment->new({
            'client_loginid' => 'CR0031',
            'currency_code'  => 'USD',
        });
    }
    'Expect to initialize payment datamapper for CR0031 USD';

    cmp_ok($payment_data_mapper->get_total_deposit,      '==', 5000, 'check total deposit of account');
    cmp_ok($payment_data_mapper->get_total_withdrawal(), '==', 500,  'check total withdrawal in USD');

    my $currency = 'GBP';
    lives_ok {
        $payment_data_mapper = BOM::Database::DataMapper::Payment->new({
            'client_loginid' => 'MX1001',
            'currency_code'  => $currency,
        });
    }
    'Expect to initialize payment datamapper for MX1001 GBP';

    cmp_ok($payment_data_mapper->get_total_deposit,      '==', 4350, 'check total deposit of account');
    cmp_ok($payment_data_mapper->get_total_withdrawal(), '==', 100,  'check total withdrawal in GBP');
    my ($start_time1, $start_time2, $end_time);
    lives_ok {
        use Date::Utility;
        $end_time    = Date::Utility->new('2011-12-01');
        $start_time1 = Date::Utility->new($end_time->epoch - 86400 * 30);
        $start_time2 = Date::Utility->new($end_time->epoch - 86400 * 300);
    }
    'Expect to initialize Date::Utility';

    cmp_ok($payment_data_mapper->get_total_withdrawal({start_time => $start_time2}),  '==', 100, 'check total withdrawal, just send start_time ');
    cmp_ok($payment_data_mapper->get_total_withdrawal({exclude    => ['excludeme']}), '==', 100, 'check total withdrawal, just send end_time ');

    lives_ok {
        $payment_data_mapper = BOM::Database::DataMapper::Payment->new({'client_loginid' => 'CR0024'});
    }
    'Expect to initialize payment datamapper for CR';
};

subtest 'get_payment_count_exclude_gateway' => sub {
    cmp_ok(
        $payment_data_mapper->get_payment_count_exclude_gateway(
            {'exclude' => ['free_gift', $BOM::Database::Model::Constants::PAYMENT_GATEWAY_DATACASH]}
        ),
        '==', 0,
        'check payment count exlude free gift, datacash'
    );

    cmp_ok($payment_data_mapper->get_payment_count_exclude_gateway({'exclude' => ['free_gift']}), '==', 1, 'check payment count exlude free gift');

    cmp_ok($payment_data_mapper->get_payment_count_exclude_gateway(), '==', 2, 'check payment count exlude free gift, datacash');
};

subtest 'get total deposit & withdrawal' => sub {
    my $currency = 'GBP';
    lives_ok {
        $payment_data_mapper = BOM::Database::DataMapper::Payment->new({
            'client_loginid' => 'MX0012',
            'currency_code'  => $currency,
        });
    }
    "Expect to initialize payment datamapper for MX0012, $currency";

    cmp_ok($payment_data_mapper->get_total_deposit,      '==', 5.04, 'check total deposit of account');
    cmp_ok($payment_data_mapper->get_total_withdrawal(), '==', 0,    'check total withdrawal of account');
};

subtest 'Payment DataMapper initial tests done.' => sub {
    plan tests => 1;

    $payment_data_mapper = BOM::Database::DataMapper::Payment->new({
        'broker_code' => 'CR',
    });
    throws_ok { $payment_data_mapper->get_client_payment_count_by() } qr/no valid client_loginid/, 'Dies on invalid client_logind';
};

subtest 'Prepare for other tests' => sub {
    plan tests => 6;

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $account = $client->set_default_account('USD');

    $payment_data_mapper = BOM::Database::DataMapper::Payment->new({client_loginid => $client->loginid});

    my $count = $payment_data_mapper->get_client_payment_count_by({payment_gateway_code => 'payment_fee'});
    is($count, 0, 'no payment count');

    $count = $payment_data_mapper->get_client_payment_count_by({
        payment_gateway_code => 'payment_fee',
        action_type          => $BOM::Database::Model::Constants::DEPOSIT,
    });
    is($count, 0, 'no payment count');

    lives_ok {
        $client->payment_payment_fee(
            amount   => 7000.25,
            remark   => 'blah',
            currency => 'USD'
        );
    }
    'Insert new payment deposit';

    $count = $payment_data_mapper->get_client_payment_count_by({payment_gateway_code => 'payment_fee'});
    is($count, 1, 'has payment count');

    $count = $payment_data_mapper->get_client_payment_count_by({
        payment_gateway_code => 'payment_fee',
        action_type          => $BOM::Database::Model::Constants::DEPOSIT,
    });
    is($count, 1, 'has payment count');

    throws_ok {
        my $new_deposit_count = $payment_data_mapper->get_client_payment_count_by({'invalid_key' => 0});
    }
    qr/Invalid parameter/, 'try invalid key in get_client_payment_count_by ';
};

subtest 'total free gift deposit' => sub {
    lives_ok {
        $payment_mapper = BOM::Database::DataMapper::Payment->new({
            'client_loginid' => 'MLT0016',
            'currency_code'  => 'GBP',
        });
    }
    'Expect to initialize the object';

    cmp_ok($payment_mapper->get_total_free_gift_deposit(), '==', 20, 'Get the free gift amount of client account');
};

subtest 'get txn id by comment' => sub {
    lives_ok {
        $payment_mapper = BOM::Database::DataMapper::Payment->new({
            'client_loginid' => 'CR2002',
            'currency_code'  => 'USD',
        });
    }
    'Expect to initialize the object';

    my $comment =
        'Moneta deposit ExternalID:CR798051270634820 TransactionID:2628125 AccountNo:93617556 CorrespondingAccountNo:93617556 Amount:USD10.00 Moneta Timestamp 28-Jun-11 10:07:49GMT';
    cmp_ok(
        $payment_mapper->get_transaction_id_of_account_by_comment({
                amount  => 10,
                comment => $comment
            }
        ),
        '!=', 0,
        'Get transaction_id'
    );

    ok(
        !$payment_mapper->get_transaction_id_of_account_by_comment({
                amount  => 10,
                comment => 'just for 100% coverage'
            }
        ),
        'Get null transaction_id for wrong comment'
    );
};

subtest 'check duplicate payment from remark' => sub {

    my $doughflow_datamapper;
    lives_ok {
        $doughflow_datamapper = BOM::Database::DataMapper::Payment::DoughFlow->new({
            client_loginid => 'CR9999',
            currency_code  => 'USD'
        });
    }
    'Expect to initialize the object';

    ok(
        $doughflow_datamapper->is_duplicate_payment({
                transaction_type => 'deposit',
                trace_id         => 1
            }
        ),
        'Check if payment is a duplicate by checking the trace_id'
    );
};

subtest 'check account has duplicate payment' => sub {
    my $loginid = 'MX1001';
    my $curr    = 'GBP';

    my $payment_mapper;
    lives_ok {
        $payment_mapper = BOM::Database::DataMapper::Payment->new({
            'client_loginid' => $loginid,
            'currency_code'  => $curr,
        });
    }
    'Expect to initialize mapper object';

    is(
        $payment_mapper->is_duplicate_manual_payment({
                remark =>
                    'Moneybookers deposit REF:MX100111271050920 ID:257054611 Email:ohoushyar@gmail.com Amount:GBP2000.00 Moneybookers Timestamp 9-Mar-11 05h44GMT',
                'date'   => Date::Utility->new({datetime => '09-Mar-11 06h22GMT'}),
                'amount' => 2000,
            }
        ),
        1,
        'Is a duplicate payment'
    );

    is(
        $payment_mapper->is_duplicate_manual_payment({
                remark =>
                    'Moneybookers deposit REF:TEST_REF ID:257054611 Email:ohoushyar@gmail.com Amount:GBP2000.00 Moneybookers Timestamp 9-Mar-11 05h44GMT',
                'date'   => Date::Utility->new({datetime => '10-Mar-11 06h22GMT'}),
                'amount' => 2000
            }
        ),
        undef,
        'NOT a duplicate payment'
    );
};

