use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Deep;
use Test::Warn;
use Date::Utility;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw( create_client );

use BOM::User::Client;
use BOM::User::Client::Status;

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
    is $client->status->no_trading->{staff_name}, 'staff1',  'staff_name was set';
    is $client->status->no_trading->{reason},     'reason1', 'reason was set';
    ok !$client->status->setnx('no_trading', 'staff2', 'reason2'), 'set_nx for existing status';
    is $client->status->no_trading->{staff_name}, 'staff1',  'staff_name was not replaced';
    is $client->status->no_trading->{reason},     'reason1', 'reason was not replaced';
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

subtest 'false profile lock' => sub {
    my $email   = 'locked_for_false_info@email.com';
    my $client1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $user = BOM::User->create(
        email          => 'locked_for_false_info@email.com',
        password       => "Coconut9009",
        email_verified => 1,
    );

    $user->add_client($client1);
    $user->add_client($client2);

    ok !$client1->locked_for_false_profile_info, 'client1 is not locked yet';
    ok !$client2->locked_for_false_profile_info, 'client2 is not locked yet';

    my @test_cases = ({
            status => 'unwelcome',
            reason => 'arbitrary reason',
            result => undef
        },
        {
            status => 'unwelcome',
            reason => 'potential corporate account - pending KYC',
            result => 1
        },
        {
            status => 'unwelcome',
            reason => 'fake profile info - pending KYC',
            result => 1
        },
        {
            status => 'cashier_locked',
            reason => 'arbitrary reason',
            result => undef
        },
        {
            status => 'cashier_locked',
            reason => 'potential corporate account - pending KYC',
            result => 1
        },
        {
            status => 'cashier_locked',
            reason => 'fake profile info - pending KYC',
            result => 1
        },
        {
            status => 'withdrawal_locked',
            reason => 'fake profile info - pending KYC',
            result => undef
        });

    for my $test_case (@test_cases) {
        $client1->status->set($test_case->{status}, 'test', $test_case->{reason});
        is $client1->locked_for_false_profile_info, $test_case->{result},
            "client's result is correct for <$test_case->{status}>, <$test_case->{reason}>";
        ok !$client2->locked_for_false_profile_info, 'Sibling client is not affected';

        reset_client_statuses($client1);
    }
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
    ok !$clear_status_code,        'Clear not hit';
    ok $client->status->unwelcome, 'Status set';
    is $client->status->reason('unwelcome'), 'first reason', 'Reason set';

    # Since the reason is the same, no need to hit _clear
    $clear_status_code = undef;
    $client->status->upsert('unwelcome', 'test', 'first reason');
    ok !$clear_status_code,        'Clear not hit';
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

    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    $client_mf->email($email);
    $client_mf->save;

    my $test_user = BOM::User->create(
        email          => $email,
        password       => 'holamundo',
        email_verified => 1,
    );

    $test_user->add_client($client_vr);
    $test_user->add_client($client_cr);
    $test_user->add_client($client_mf);

    my $clients = [$client_mf, $client_cr, $client_vr];

    my $cases = [{
            status  => 'allow_poi_resubmission',
            settler => $client_mf,
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

    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    $client_mf->email($email);
    $client_mf->save;

    my $test_user = BOM::User->create(
        email          => $email,
        password       => 'holamundo',
        email_verified => 1,
    );

    $test_user->add_client($client_vr);
    $test_user->add_client($client_cr);
    $test_user->add_client($client_mf);

    my $clients = [$client_mf, $client_cr, $client_vr];

    my $cases = [{
            status  => 'allow_poi_resubmission',
            remover => $client_mf,
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

subtest 'Forged Documents Status' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    ok !$client->has_forged_documents, 'Client does not have forged documents';

    $client->status->upsert('cashier_locked', 'test', 'Forged document');

    $client->status->_build_all;    # reload

    ok $client->has_forged_documents, 'Client has forged documents';

    $client->status->_build_all;    # reload

    $client->status->upsert('cashier_locked', 'test', 'The guy said he has forged document but I, officially, dunno');

    ok !$client->has_forged_documents, 'Client does not forged documents as the regex is not matched';

    $client->status->upsert('no_trading', 'test', 'Forged document - based on SOP');

    $client->status->_build_all;    # reload

    ok $client->has_forged_documents, 'Client has forged document again';

    $client->status->upsert('disabled', 'test', 'Forged document - based on SOP');

    $client->status->clear_no_trading;    # calling clear_* also reloads the object state, no need to _build_all

    ok !$client->has_forged_documents, 'Client does not have forged documents - the status is not in the SOP';

    $client->status->upsert('cashier_locked', 'test');

    $client->status->_build_all;          # reload

    ok !$client->has_forged_documents, 'Client does not have forged documents on empty reason';

    $client->status->upsert('cashier_locked', 'test', 'forged dOCUMENT - based on SOP');

    $client->status->_build_all;          # reload

    ok $client->has_forged_documents, 'Client has forged document - insensitive case';
};

subtest 'Deposit Attempt' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $client->status->_build_all;          # reload

    ok !$client->status->deposit_attempt, "Client didn't have a deposit attempt";

    $client->status->upsert('deposit_attempt', 'test', 'Client attempted a deposit');

    $client->status->_build_all;          # reload

    ok $client->status->deposit_attempt, 'deposit_attempt is set';

    $client->status->clear_deposit_attempt;

    $client->status->_build_all;          # reload

    ok !$client->status->deposit_attempt, 'deposit_attempt is removed';
};

subtest 'can_copy' => sub {
    my $mock = Test::MockModule->new('BOM::User::Client::Status');

    sub mock_config {
        my ($mock, $config) = @_;

        $mock->mock(
            'get_status_config',
            sub {
                my $status_code = shift;
                return $config->{$status_code};
            });

    }

    subtest 'Check for applied_by' => sub {

        my @test_cases = ({
                'applied_by' => {
                    'system' => 1,
                    'staff'  => 1,
                },
                'expected' => {
                    'system' => 1,
                    'staff'  => 1,
                }
            },
            {
                'applied_by' => {
                    'system' => 1,
                    'staff'  => 0,
                },
                'expected' => {
                    'system' => 1,
                    'staff'  => 0,
                }
            },
            {
                'applied_by' => {
                    'system' => 0,
                    'staff'  => 1,
                },
                'expected' => {
                    'system' => 0,
                    'staff'  => 1,
                }
            },
            {
                'applied_by' => {
                    'system' => 0,
                    'staff'  => 0,
                },
                'expected' => {
                    'system' => 0,
                    'staff'  => 0,
                }});

        for my $test_case (@test_cases) {
            mock_config(
                $mock,
                {
                    'age_verification' => {'CR_MF' => {'applied_by' => $test_case->{'applied_by'}}},
                });

            ok BOM::User::Client::Status::can_copy('age_verification', 'CR', 'MF', 'system') == $test_case->{'expected'}->{'system'},
                'Allowed if applied by system';
            ok BOM::User::Client::Status::can_copy('age_verification', 'CR', 'MF', 'staff') == $test_case->{'expected'}->{'staff'},
                'Allowed if applied by staff';
        }
    };

    subtest 'Check for broker code' => sub {

        my @broker_codes = qw(CR MF VR);
        my @combinations = qw(CR_CR MF_MF MF_CR CR_MF VR_CR CR_VR MF_CR CR_MF);

        my @test_cases = ({
                'disallowed_combination' => 'CR_CR',
                'allowed_combination'    => 'CR_MF',
                'from_broker_code'       => 'CR',
                'to_broker_code'         => 'CR',
                'expected'               => 0,
                'test_description'       => 'Disallowed if combination is not allowed'
            },
            {
                'disallowed_combination' => 'MF_CR',
                'allowed_combination'    => 'CR_MF',
                'from_broker_code'       => 'MF',
                'to_broker_code'         => 'CR',
                'expected'               => 0,
                'test_description'       => 'Disallowed even if reverse combination is allowed'
            },
            {
                'disallowed_combination' => 'CR_CR',
                'allowed_combination'    => 'CR_MF',
                'from_broker_code'       => 'CR',
                'to_broker_code'         => 'MF',
                'expected'               => 1,
                'test_description'       => 'Allowed if combination is allowed'
            });

        for my $test_case (@test_cases) {
            mock_config(
                $mock,
                {
                    'age_verification' => {
                        $test_case->{'disallowed_combination'} => {
                            'applied_by' => {
                                'system' => 0,
                                'staff'  => 0,
                            }
                        },
                        $test_case->{'allowed_combination'} => {
                            'applied_by' => {
                                'system' => 1,
                                'staff'  => 1,
                            }}
                    },
                });

            ok BOM::User::Client::Status::can_copy('age_verification', $test_case->{'from_broker_code'}, $test_case->{'to_broker_code'}, 'system') ==
                $test_case->{'expected'}, $test_case->{'test_description'};
        }

    };

    subtest 'Default values' => sub {
        mock_config(
            $mock,
            {
                'age_verification' => {
                    'CR_MF' => {
                        'applied_by' => {
                            'system' => 0,
                            'staff'  => 0,
                        }}
                },
            });

        ok BOM::User::Client::Status::can_copy('disabled', 'CR', 'MF', 'system') == 0, 'If status is not found, default would be 0';
        ok BOM::User::Client::Status::can_copy('age_verification', 'MF', 'CR', 'staff') == 0,
            'If broker combination is not found, default would be 1';

        mock_config(
            $mock,
            {
                'age_verification' => {
                    'CR_MF' => {
                        'applied_by' => {
                            'system' => 0,
                        }}
                },
            });

        ok BOM::User::Client::Status::can_copy('age_verification', 'CR', 'MF', 'staff') == 0, 'If staff is not found, default would be 0';
    };

    $mock->unmock_all;

};

subtest 'Status Hierarchy' => sub {
    my $mock   = Test::MockModule->new('BOM::User::Client::Status');
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    subtest 'Multiple Roots' => sub {

        mock_hierarchy(
            $mock,
            {
                'age_verification'       => ['cashier_locked'],
                'professional_requested' => ['professional'],
            });

        subtest 'Set' => sub {
            $client->status->set('cashier_locked', 'test', 'test_reason');
            ok $client->status->age_verification,        'age_verification is set';
            ok $client->status->cashier_locked,          'cashier_locked is set';
            ok !$client->status->professional_requested, 'professional_requested is not set';
            ok !$client->status->professional,           'professional is not set';

            $client->status->clear_age_verification;

            $client->status->set('professional', 'test', 'test_reason');
            ok $client->status->professional_requested, 'professional_requested is set';
            ok $client->status->professional,           'professional is set';
            ok !$client->status->age_verification,      'age_verification is not set';
            ok !$client->status->cashier_locked,        'cashier_locked is not set';

        };

        subtest 'Clear' => sub {
            reset_client_statuses($client);
            $client->status->set('cashier_locked', 'test', 'test_reason');
            $client->status->set('professional',   'test', 'test_reason');

            $client->status->clear_age_verification;
            ok !$client->status->age_verification,      'age_verification is not set';
            ok !$client->status->cashier_locked,        'cashier_locked is not set';
            ok $client->status->professional_requested, 'professional_requested is set';
            ok $client->status->professional,           'professional is set';

            $client->status->clear_professional_requested;
            ok !$client->status->professional_requested, 'professional_requested is not set';
            ok !$client->status->professional,           'professional is not set';

        };

    };

    subtest 'Multiple Children' => sub {

        mock_hierarchy(
            $mock,
            {
                'age_verification' => ['cashier_locked', 'professional_requested'],
            });

        subtest 'Set' => sub {
            $client->status->set('cashier_locked', 'test', 'test_reason');
            ok $client->status->age_verification,        'age_verification is set';
            ok $client->status->cashier_locked,          'cashier_locked is set';
            ok !$client->status->professional_requested, 'professional_requested is not set';

            ok $client->status->set('professional_requested', 'test', 'test_reason');
            ok $client->status->age_verification,       'age_verification is set';
            ok $client->status->cashier_locked,         'cashier_locked is set';
            ok $client->status->professional_requested, 'professional_requested is set';

        };

        subtest 'Clear' => sub {
            reset_client_statuses($client);
            $client->status->set('cashier_locked',         'test', 'test_reason');
            $client->status->set('professional_requested', 'test', 'test_reason');

            $client->status->clear_age_verification;
            ok !$client->status->age_verification,       'age_verification is not set';
            ok !$client->status->cashier_locked,         'cashier_locked is not set';
            ok !$client->status->professional_requested, 'professional_requested is not set';

        };

    };

    subtest 'Existing parent statuses' => sub {
        $client->status->set('age_verification',       'test', 'test_reason');
        $client->status->set('professional_requested', 'test', 'test_reason');

        $client->status->set('cashier_locked', 'test', 'test_reason 2');
        ok $client->status->age_verification,                            'age_verification is set';
        ok $client->status->reason('age_verification') eq 'test_reason', 'reason is correct. Did not affect parent status';
        ok $client->status->cashier_locked,                              'cashier_locked is set';
        ok $client->status->reason('cashier_locked') eq 'test_reason 2', 'reason is correct. Did not affect self status';

    };

    mock_hierarchy(
        $mock,
        {
            'age_verification'       => ['cashier_locked'],
            'professional_requested' => ['professional'],
        });

    subtest 'Setnx' => sub {
        reset_client_statuses($client);
        $client->status->set('cashier_locked', 'test', 'test_reason');
        $client->status->set('professional',   'test', 'test_reason');
        $client->status->_build_all;
        ok !$client->status->setnx('age_verification', 'test', 'test_reason'), 'age verification was already set';
        ok $client->status->age_verification,                                  'age_verification is set';
        ok $client->status->cashier_locked,                                    'cashier_locked is set';
        ok $client->status->professional_requested,                            'professional_requested is set';
        ok $client->status->professional,                                      'professional is set';

        $client->status->clear_age_verification;
        $client->status->clear_cashier_locked;
        $client->status->clear_professional_requested;

        ok $client->status->setnx('professional', 'test', 'test_reason'), 'professional was not already set';
        ok $client->status->professional_requested,                       'professional_requested is set';
        ok $client->status->professional,                                 'professional is set';

    };

    subtest 'Upsert' => sub {
        reset_client_statuses($client);
        $client->status->set('cashier_locked', 'test', 'test_reason');
        $client->status->set('professional',   'test', 'test_reason');
        ok $client->status->cashier_locked, 'cashier_locked is set';
        ok $client->status->professional,   'professional is set';

        ok $client->status->upsert('cashier_locked', 'test', 'test_reason_1');

        ok $client->status->cashier_locked,                              'cashier_locked is set';
        ok $client->status->age_verification,                            'age_verification is set';
        ok $client->status->reason('cashier_locked') eq 'test_reason_1', 'reason is correct';

        ok $client->status->reason('age_verification') eq 'test_reason', 'reason is correct';
        ok $client->status->reason('professional') eq 'test_reason',     'reason is correct';

    };

    $mock->unmock_all;

};

subtest 'is_executable' => sub {
    my $mock = Test::MockModule->new('BOM::User::Client::Status');

    my $config = {
        config => {
            dummy_status => {
                DummyGroup1 => 1,
            },
            dummy_status2 => {
                DummyGroup1 => 1,
            },
        }

    };

    my $test_cases = [{
            groups   => ['dummy_status'],
            status   => ['non_existing_status'],
            expected => 1,
            message  => 'non_existing_status is not in the config -> allowed'
        },
        {
            groups   => ['NonExistingGroup1', 'NonExistingGroup2'],
            status   => 'dummy_status',
            expected => 0,
            message  => 'NonExistingGroup1 and NonExistingGroup2 are not in the config -> not allowed'
        },
        {
            groups   => ['DummyGroup1', 'DummyGroup2'],
            status   => 'dummy_status1',
            expected => 1,
            message  => 'dummy_status1 is in config with DummyGroup1 -> allowed'
        }];
    mock_rights($mock, $config);

    for my $test_case (@$test_cases) {
        my $groups   = $test_case->{groups};
        my $status   = $test_case->{status};
        my $expected = $test_case->{expected};
        my $message  = $test_case->{message};

        is BOM::User::Client::Status::is_executable($status, $groups), $expected, $message;
    }

    $mock->unmock_all;
};

subtest 'can_execute' => sub {
    my $mock   = Test::MockModule->new('BOM::User::Client::Status');
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    mock_hierarchy(
        $mock,
        {
            'age_verification'       => ['cashier_locked'],
            'professional_requested' => ['professional', 'disabled'],
        });

    my $config = {
        config => {
            age_verification => {
                DummyGroup1 => 1,
            },
            professional => {
                DummyGroup2 => 1,
            },
            disabled => {
                DummyGroup3 => 1,
            },
        }};
    mock_rights($mock, $config);

    my $set_test_cases = [{
            status   => 'age_verification',
            groups   => ['DummyGroup1'],
            expected => 1,
            message  => 'age_verification can be set by DummyGroup1'
        },
        {
            status   => 'age_verification',
            groups   => ['DummyGroup2'],
            expected => 0,
            message  => 'age_verification can not be set by DummyGroup2'
        },
        {
            status   => 'cashier_locked',
            groups   => ['DummyGroup1'],
            expected => 1,
            message  => 'cashier_locked along with parent age_verification can be set by DummyGroup1'
        },
        {
            status   => 'cashier_locked',
            groups   => ['DummyGroup2'],
            expected => 0,
            message  => 'cashier_locked can not be set by DummyGroup2 as age_verification is not allowed'
        },
        {
            status   => 'professional',
            groups   => ['DummyGroup2'],
            expected => 1,
            message  => 'professional along with parent professional_requested can be set by DummyGroup2'
        }];

    for my $test_case (@$set_test_cases) {
        my $status   = $test_case->{status};
        my $groups   = $test_case->{groups};
        my $expected = $test_case->{expected};
        my $message  = $test_case->{message};

        is $client->status->can_execute($status, $groups, 'set'), $expected, $message;
    }

    # status removal test cases
    is $client->status->can_execute('cashier_locked', ['DummyGroup1'], 'remove'), 1, 'cashier_locked can be removed by DummyGroup1';

    $client->status->setnx('cashier_locked', 'test', 'test_reason');
    is $client->status->can_execute('age_verification', ['DummyGroup1'], 'remove'), 1,
        'age_verification can be removed by DummyGroup1 along with its child cashier_locked';
    is $client->status->can_execute('age_verification', ['DummyGroup2'], 'remove'), 0, 'age_verification can not be removed by DummyGroup2';

    $client->status->setnx('professional', 'test', 'test_reason');
    is $client->status->can_execute('professional_requested', ['DummyGroup2'], 'remove'), 1,
        'professional_requested can be removed by DummyGroup2 along with its child';
    is $client->status->can_execute('professional_requested', ['DummyGroup1'], 'remove'), 0,
        'professional_requested can not be removed by DummyGroup1 as removal of child is not allowed';
    is $client->status->can_execute('professional', ['DummyGroup1'], 'remove'), 0, 'professional can not be removed by DummyGroup1';
    is $client->status->can_execute('professional', ['DummyGroup2'], 'remove'), 1, 'professional can be removed by DummyGroup2';

    reset_client_statuses($client);

    $mock->unmock_all;
};

sub reset_client_statuses {
    my $client = shift;
    $client->status->multi_set_clear({clear => $client->status->all});
    cmp_deeply($client->status->all, [], ' client statuses reset successfully ');
}

sub mock_rights {
    my ($mock, $config) = @_;

    $mock->mock(
        'get_status_rights_config',
        sub {
            my ($status_code) = @_;
            return $config->{config}->{$status_code};
        });
}

sub mock_hierarchy {
    my ($mock, $hierarchy) = @_;

    $mock->mock(
        'children',
        sub {
            my ($status_code) = @_;
            my $children = $hierarchy->{$status_code} // [];
            return $children->@*;
        });
    $mock->mock(
        'parent',
        sub {
            my ($status_code) = @_;
            return BOM::User::Client::Status::_build_parent_map($hierarchy)->{$status_code};
        });
}

done_testing();
