use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Warn;
use Date::Utility;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );

use BOM::User::Client;

my $client = create_client();
my $res;

subtest 'Setter' => sub {
    subtest 'Set new' => sub {
        $res = $client->status->set('age_verification', 'test_name', 'test_reason');
        ok($res, 'New insert succeeds');
        $client->status->clear_age_verification;
    };

    subtest 'Set existing with new details' => sub {
        $res = $client->status->set('age_verification', 'test_name2', 'test_reason2');
        ok($res, 'Existing with new details succeeds');
        $client->status->clear_age_verification;
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

    subtest 'Overriding status reason fails' => sub {
        throws_ok {
            warning_like {
                $res = $client->status->set('age_verification');
            }
            qr/duplicate key value violates unique constraint/, 'Warns with duplicate status';
        }
        qr/duplicate key value violates unique constraint/, 'Dies with duplicate status';
    };
};

subtest 'Set NX' => sub {
    ok $client->status->setnx('no_trading', 'staff1', 'reason1'), 'set_nx for new status';
    is $client->status->no_trading->{staff_name}, 'staff1', 'staff_name was set';
    is $client->status->no_trading->{reason}, 'reason1', 'reason was set';
    ok !$client->status->setnx('no_trading', 'staff2', 'reason2'), 'set_nx for existing status';
    is $client->status->no_trading->{staff_name}, 'staff1', 'staff_name was not replaced';
    is $client->status->no_trading->{reason}, 'reason1', 'reason was not replaced';
    $client->status->clear_no_trading;
};

subtest 'Getter' => sub {

    subtest 'Get record' => sub {
        $res = $client->status->age_verification;

        ok(abs(Date::Utility->new($res->{last_modified_date})->{epoch} - Date::Utility->new()->{epoch}) <= 1,
            'date modified is now (1 sec test tolerance)');
        is($res->{staff_name}, 'test_name2',   'staff_name is correct');
        is($res->{reason},     'test_reason2', 'reason is correct');
    };

    subtest 'Get record that does not exist' => sub {
        $res = $client->status->withdrawal_locked;
        is($res, undef, 'Non existent record returns undef');
    };

    subtest 'Get list of all' => sub {
        my $list = $client->status->all;
        cmp_deeply($list, ['age_verification', 'cashier_locked'], 'status_code list is correct');
    };

    subtest 'Get list of all with hidden' => sub {
        $res = $client->status->set('duplicate_account');
        ok($res, 'Successfully set hidden status_code');

        my $list1 = $client->status->visible;
        cmp_deeply($list1, ['age_verification', 'cashier_locked'], 'status_code list returns without hidden code');

        my $list2 = $client->status->all;
        cmp_deeply($list2, ['age_verification', 'cashier_locked', 'duplicate_account'], 'status_code list returns without hidden code');
    };
};

subtest 'Clear' => sub {

    subtest 'Ensure age_verification set' => sub {
        $res = $client->status->age_verification;
        ok($res, 'Age Verification is Set');
    };

    subtest 'Clear record' => sub {
        $client->status->clear_age_verification();
        $res = $client->status->age_verification;
        is($res, undef, 'status has been cleared');
        my $loginid = $client->loginid;
        my $result  = $client->db->dbic->run(
            fixup => sub {
                $_->selectcol_arrayref("
                    SELECT * FROM betonmarkets.client_status WHERE client_loginid = ?
                        AND status_code = 'age_verification'",
                    undef,
                    $loginid);
            });
        is(scalar(@$result), 0, 'record cleared from table');
    };

    subtest 'Clear record already cleared' => sub {
        $client->status->clear_age_verification();
        $res = $client->status->age_verification;
        is($res, undef, 'Repeat clear succeeds');
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
        my $list1 = $client->status->all;
        cmp_deeply($list1, ['age_verification', 'professional', 'professional_requested'], 'correct status_code list returns');

        $res = $client->status->age_verification;
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

        ok(!$client->status->age_verification, 'age_verification unset');
        my $list1 = $client->status->all;
        cmp_deeply($list1, ['disabled', 'professional', 'unwelcome'], 'correct status_code list returns');
    };

    subtest 'Multi-clear' => sub {
        $res = $client->status->multi_set_clear({
            clear => ['disabled', 'unwelcome'],
        });
        ok($res, "Multi-clear returns successfully");

        ok(!$client->status->unwelcome, 'unwelcome unset');
        my $list1 = $client->status->all;
        cmp_deeply($list1, ['professional'], 'correct status_code list returns');
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

    $res = $client->status->is_login_disallowed;
    is($res, 0, 'login is not disallowed');

    $res = $client->status->set('duplicate_account', 'test_name', 'test_reason');
    ok($res, 'Dupliate account set succeeds');

    $res = $client->status->is_login_disallowed;
    is($res, 1, 'login is disallowed');

    $client->status->clear_duplicate_account();
    $res = $client->status->duplicate_account;
    is($res, undef, 'Clear succeeds');

    $res = $client->status->is_login_disallowed;
    is($res, 0, 'login is not disallowed');
};

subtest 'closed status code' => sub {
    reset_client_statuses($client) if $client->status->all->@*;
    $client->status->set('disabled', 'test', 'just for testing closed status');
    $client->status->set('closed',   'test', 'just for testing');
    cmp_deeply($client->status->all, ['closed', 'disabled'], 'disabled and closed status codes added');

    $client->status->clear_closed;
    cmp_deeply($client->status->all, ['disabled'], 'disabled status is not removed if closed status is cleared');

    $client->status->set('closed', 'test', 'reverting the disabled status');
    cmp_deeply($client->status->all, ['closed', 'disabled'], 'disabled and closed status codes are back now');
    $client->status->clear_disabled;
    cmp_deeply($client->status->all, [], 'closed status is removed along with disabled status');
};

subtest 'Upsert' => sub {
    reset_client_statuses($client) if $client->status->all->@*;
    my $mock = Test::MockModule->new('BOM::User::Client::Status');
    my $clear_status_code;

    $mock->mock(
        '_clear',
        sub {
            (undef, $clear_status_code) = @_;
            return $mock->original('_clear')->(@_);
        });
    # A fresh client should not hit the _clear method
    $client->status->upsert('unwelcome', 'test', 'first reason');
    ok !$clear_status_code, 'Clear not hit';
    ok $client->status->unwelcome, 'Status set';
    is $client->status->reason('unwelcome'), 'first reason', 'Reason set';

    # Since the reason is the same, no need to hit _clear
    $clear_status_code = undef;
    $client->status->upsert('unwelcome', 'test', 'first reason');
    ok !$clear_status_code, 'Clear not hit';
    ok $client->status->unwelcome, 'Status set';
    is $client->status->reason('unwelcome'), 'first reason', 'Reason remains';

    # Now the reason has changed and so we hit _clear
    $clear_status_code = undef;
    $client->status->upsert('unwelcome', 'test', 'second reason');
    is $clear_status_code, 'unwelcome', 'Clear was hit';
    ok $client->status->unwelcome, 'Status set';
    is $client->status->reason('unwelcome'), 'second reason', 'Reason updated';

    $mock->unmock_all;
};

subtest 'Propagate' => sub {
    my $email     = 'propa@gation.com';
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    $client_vr->email($email);
    $client_vr->save;

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->email($email);
    $client_cr->save;

    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    $client_mlt->email($email);
    $client_mlt->save;

    my $test_user = BOM::User->create(
        email          => $email,
        password       => 'holamundo',
        email_verified => 1,
    );

    $test_user->add_client($client_vr);
    $test_user->add_client($client_cr);
    $test_user->add_client($client_mlt);

    my $clients = [$client_mlt, $client_cr, $client_vr];

    my $cases = [{
            status  => 'allow_poi_resubmission',
            settler => $client_mlt,
            staff   => 'alice',
            reason  => 'alices reason'
        },
        {
            status  => 'allow_poi_resubmission',
            settler => $client_cr,
            staff   => 'bob',
            reason  => 'bobs reason'
        },
        {
            status  => 'allow_poa_resubmission',
            settler => $client_vr,
            staff   => 'chuck',
            reason  => 'chucks reason'
        },
    ];

    for my $case ($cases->@*) {
        my $settler = $case->{settler};
        my $status  = $case->{status};
        my $staff   = $case->{staff};
        my $reason  = $case->{reason};

        subtest join(' ', $settler->loginid, 'propagating', $status, 'by', $staff, 'with', $reason) => sub {
            $settler->propagate_status($status, $staff, $reason);

            for my $client ($clients->@*) {
                my $current_status = $client->status->_get($status);

                if ($client->is_virtual) {
                    ok !$current_status, 'Not propagated to virtual account ' . $client->loginid;
                } else {
                    cmp_deeply $current_status,
                        {
                        reason             => $reason,
                        staff_name         => $staff,
                        status_code        => $status,
                        last_modified_date => re('.+'),
                        },
                        'Status successfully propagated to ' . $client->loginid;
                }
            }
        }
    }
};

subtest 'Propagate Clear' => sub {
    my $email     = 'propa@gation2.com';
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    $client_vr->email($email);
    $client_vr->save;

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->email($email);
    $client_cr->save;

    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    $client_mlt->email($email);
    $client_mlt->save;

    my $test_user = BOM::User->create(
        email          => $email,
        password       => 'holamundo',
        email_verified => 1,
    );

    $test_user->add_client($client_vr);
    $test_user->add_client($client_cr);
    $test_user->add_client($client_mlt);

    my $clients = [$client_mlt, $client_cr, $client_vr];

    my $cases = [{
            status  => 'allow_poi_resubmission',
            remover => $client_mlt,
        },
        {
            status  => 'allow_document_upload',
            remover => $client_cr,
        },
        {
            status  => 'allow_poa_resubmission',
            remover => $client_vr,
        },
    ];

    for my $case ($cases->@*) {
        my $remover = $case->{remover};
        my $status  = $case->{status};

        subtest join(' ', $remover->loginid, 'propagating', $status, 'removal') => sub {
            $_->status->set($status) for ($clients->@*);
            $remover->propagate_clear_status($status);

            for my $client ($clients->@*) {
                my $current_status = $client->status->_get($status);

                if ($client->is_virtual) {
                    ok $current_status, 'Not removed from virtual account ' . $client->loginid;
                } else {
                    ok !$current_status, 'Removed from real account ' . $client->loginid;
                }
            }
        }
    }
};

done_testing();

sub reset_client_statuses {
    my $client = shift;
    $client->status->multi_set_clear({clear => $client->status->all});
    cmp_deeply($client->status->all, [], ' client statuses reset successfully ');
}
