use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Warn;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

use BOM::User::Client;

my $client = create_client();
my $res;

subtest 'Setter' => sub {
    subtest 'Set new' => sub {
        $res = $client->status->set('age_verification', 'test_name', 'test_reason');
        ok($res, 'New insert succeeds');
    };

    subtest 'Set existing with new details' => sub {
        $res = $client->status->set('age_verification', 'test_name2', 'test_reason2');
        ok($res, 'Existing with new details succeeds');
    };

    subtest 'Set existing with same details' => sub {
        $res = $client->status->set('age_verification', 'test_name2', 'test_reason2');
        ok($res, 'Existing with same details succeeds');
    };

    subtest 'Staff name and reason are optional' => sub {
        $res = $client->status->set('cashier_locked');
        ok($res, 'Accept set without staff name and reason');
    };

    subtest 'Status code is required' => sub {
        throws_ok {
            $res = $client->status->set();
        }
        qr/status_code is required/, 'Dies without status_code';
    };

    subtest 'Invalid status code rejected' => sub {
        throws_ok {
            warning_like {
                $res = $client->status->set('invalid');
            }
            qr/foreign key constraint/, 'Warns with invalid status_code';
        }
        qr/foreign key constraint/, 'Dies with invalid status_code';
    };
};

subtest 'Getter' => sub {
    subtest 'Status code is required' => sub {
        throws_ok {
            $res = $client->status->get();
        }
        qr/status_code is required/, 'Dies without status_code';
    };

    subtest 'Get record' => sub {
        $res = $client->status->get('age_verification');

        ok(abs(Date::Utility->new($res->{last_modified_date})->{epoch} - Date::Utility->new()->{epoch}) <= 1,
            'date modified is now (1 sec test tolerance)');
        is($res->{staff_name}, 'test_name2',   'staff_name is correct');
        is($res->{reason},     'test_reason2', 'reason is correct');
    };

    subtest 'Get record that does not exist' => sub {
        $res = $client->status->get('withdrawal_locked');
        is($res, undef, 'Non existent record returns undef');
    };

    subtest 'Get list of all' => sub {
        my @list = $client->status->all();
        cmp_deeply(\@list, ['age_verification', 'cashier_locked'], 'status_code list is correct');
    };

    subtest 'Get list of all with hidden' => sub {
        $res = $client->status->set('duplicate_account');
        ok($res, 'Successfully set hidden status_code');

        my @list1 = $client->status->visible();
        cmp_deeply(\@list1, ['age_verification', 'cashier_locked'], 'status_code list returns without hidden code');

        my @list2 = $client->status->all();
        cmp_deeply(\@list2, ['age_verification', 'cashier_locked', 'duplicate_account'], 'status_code list returns without hidden code');
    };
};

subtest 'Clear' => sub {
    subtest 'Clear record' => sub {
        $res = $client->status->clear('age_verification');
        ok($res, 'Clear succeeds');
    };

    subtest 'Clear record already cleared' => sub {
        $res = $client->status->clear('age_verification');
        ok($res, 'Repeat clear succeeds');
    };

    subtest 'Status code is required' => sub {
        throws_ok {
            $res = $client->status->clear();
        }
        qr/status_code is required/, 'Dies without status_code';
    };
};

subtest 'Multi setter and clear' => sub {
    reset_client_statuses($client);

    subtest 'Multi-set' => sub {
        $res = $client->status->multi_set_clear({
            set        => ['age_verification', 'professional_requested', 'professional'],
            staff_name => 'me',
            reason     => 'because',
        });
        ok($res, "Multi-set returns successfully");

        my @list1 = $client->status->all();
        cmp_deeply([sort @list1], ['age_verification', 'professional', 'professional_requested'], 'correct status_code list returns');

        $res = $client->status->get('age_verification');
        ok(abs(Date::Utility->new($res->{last_modified_date})->{epoch} - Date::Utility->new()->{epoch}) <= 1,
            'date modified is now (1 sec test tolerance)');
        is($res->{staff_name}, 'me',      'staff_name is correct');
        is($res->{reason},     'because', 'reason is correct');
    };

    subtest 'Multi-set and multi-clear' => sub {
        $res = $client->status->multi_set_clear({
            set        => ['disabled',         'unwelcome'],
            clear      => ['age_verification', 'professional_requested'],
            staff_name => 'me',
            reason     => 'because',
        });
        ok($res, "Multi-set and multi-clear returns successfully");

        my @list1 = $client->status->all();
        cmp_deeply([sort @list1], ['disabled', 'professional', 'unwelcome'], 'correct status_code list returns');
    };

    subtest 'Multi-clear' => sub {
        $res = $client->status->multi_set_clear({
            clear => ['disabled', 'unwelcome'],
        });
        ok($res, "Multi-clear returns successfully");

        my @list1 = $client->status->all();
        cmp_deeply(\@list1, ['professional'], 'correct status_code list returns');
    };

    subtest 'Unique violation 1' => sub {
        throws_ok {
            $res = $client->status->multi_set_clear({
                set   => [' age_verification '],
                clear => [' age_verification '],
            });
        }
        qr/All specified status_codes must be unique/, ' Dies with repeated status_code in set & clear ';
    };

    subtest ' Unique violation 2' => sub {
        throws_ok {
            $res = $client->status->multi_set_clear({
                set => ['age_verification', 'age_verification'],
            });
        }
        qr/All specified status_codes must be unique/, 'Dies with repeated status_code in set';
    };

    subtest 'Unique violation 3' => sub {
        throws_ok {
            $res = $client->status->multi_set_clear({
                clear => [' age_verification ', ' age_verification '],
            });
        }
        qr/All specified status_codes must be unique/, ' Dies with repeated status_code in clear ';
    };
};

subtest 'is_login_disallowed' => sub {
    reset_client_statuses($client);

    $res = $client->status->is_login_disallowed();
    is($res, 0, 'login is not disallowed');

    $res = $client->status->set('duplicate_account', 'test_name', 'test_reason');
    ok($res, 'Dupliate account set succeeds');

    $res = $client->status->is_login_disallowed();
    is($res, 1, 'login is disallowed');

    $res = $client->status->clear('duplicate_account');
    ok($res, 'Clear succeeds');

    $res = $client->status->is_login_disallowed();
    is($res, 0, 'login is not disallowed');
};

done_testing();

sub reset_client_statuses {
    my $client = shift;
    $client->status->multi_set_clear({clear => [$client->status->all()]});
    is($client->status->all(), 0, ' client statuses reset successfully ');
}
