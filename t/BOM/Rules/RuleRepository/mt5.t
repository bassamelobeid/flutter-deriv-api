use strict;
use warnings;

use Test::Most;
use Test::MockModule;
use Test::Fatal;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;
use BOM::User;

use Date::Utility;

my $rule_name = 'mt5_account.account_poa_status_allowed';
subtest $rule_name => sub {
    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $poa_status  = 'none';
    my $poi_status  = 'none';

    $client_mock->mock(
        'get_poa_status',
        sub {
            return $poa_status;
        });
    $client_mock->mock(
        'get_poi_status',
        sub {
            return $poi_status;
        });
    $client_mock->mock(
        'get_poi_status_jurisdiction',
        sub {
            return $poi_status;
        });

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'mt5+poa+checks@test.com',
    });

    BOM::User->create(
        email    => $client_cr->email,
        password => 'x',
    )->add_client($client_cr);

    $client_cr->account('USD');

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

    # undefined group

    my $args = {
        loginid         => $client_cr->loginid,
        loginid_details => {
            MTR1000 => {attributes => {group => undef}},
        },
        mt5_id => 'MTR1000',
    };

    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes for undefined group within a defined mt5 loginid';

    # defined group
    # jurisdiction is undef

    $args = {
        loginid         => $client_cr->loginid,
        loginid_details => {
            MTR1000 => {attributes => {group => 'TEST'}},
        },
        mt5_id => 'MTR1000',
    };

    $poa_status = 'none';

    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes when jurisdiction is undef';

    # defined group
    # jurisdiction has no limits

    $args = {
        loginid              => $client_cr->loginid,
        new_mt5_jurisdiction => 'svg',
        loginid_details      => {
            MTR1000 => {attributes => {group => 'TEST'}},
        },
        mt5_id => 'MTR1000',
    };

    $poa_status = 'none';

    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes for jurisdiction without limits';

    # defined group
    # jurisdiction has limits
    # mt5 id status = active

    $args = {
        loginid              => $client_cr->loginid,
        new_mt5_jurisdiction => 'bvi',
        loginid_details      => {
            MTR1000 => {
                attributes => {
                    group => 'bvi',
                },
                status => 'active',
            },
        },
        mt5_id => 'MTR1000',
    };

    $poa_status = 'none';

    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes when jurisdiction has limits, status = active';

    # defined group, poa status is none
    # jurisdiction has limits
    # mt5 id status = active

    $args = {
        loginid              => $client_cr->loginid,
        new_mt5_jurisdiction => 'bvi',
        loginid_details      => {
            MTR1000 => {
                attributes => {
                    group => 'bvi',
                },
                status => undef,
            },
        },
        mt5_id => 'MTR1000',
    };

    $poa_status = 'none';

    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes when jurisdiction has limits, status = undef';

    # defined group
    # jurisdiction has limits
    # mt5 id status = not verified

    for my $status (qw/expired none pending rejected/) {
        for my $loginid_status (qw/poa_failed/) {
            $args = {
                loginid              => $client_cr->loginid,
                new_mt5_jurisdiction => 'vanuatu',
                loginid_details      => {
                    MTR1000 => {
                        attributes => {group => 'vanuatu'},
                        status     => $loginid_status,
                    },
                },
                mt5_id => 'MTR1000',
            };

            $poa_status = $status;

            cmp_deeply(
                exception { $rule_engine->apply_rules($rule_name, $args->%*) },
                {
                    error_code => 'POAVerificationFailed',
                    rule       => $rule_name
                },
                "POA Failed status = $status, loginid status = $loginid_status"
            );
        }

        for my $loginid_status (qw/poa_outdated poa_pending poa_rejected proof_failed verification_pending/) {
            $args = {
                loginid              => $client_cr->loginid,
                new_mt5_jurisdiction => 'vanuatu',
                loginid_details      => {
                    MTR1000 => {
                        attributes => {group => 'vanuatu'},
                        status     => $loginid_status,
                    },
                },
                mt5_id => 'MTR1000',
            };

            $poa_status = $status;

            if ($poa_status eq 'expired') {
                cmp_deeply(
                    exception { $rule_engine->apply_rules($rule_name, $args->%*) },
                    {
                        error_code => 'POAVerificationFailed',
                        rule       => $rule_name,
                        params     => {mt5_status => 'poa_outdated'}
                    },
                    "POA Failed status = $status, loginid status = $loginid_status"
                );
            } else {
                ok $rule_engine->apply_rules($rule_name, $args->%*), "Rule does not fail status = $status, loginid status = $loginid_status";
            }
        }
    }

    # defined group
    # jurisdiction has limits
    # mt5 id status = verified
    $args = {
        loginid              => $client_cr->loginid,
        new_mt5_jurisdiction => 'vanuatu',
        loginid_details      => {
            MTR1000 => {
                attributes => {group => 'vanuatu'},
                status     => 'poa_failed',
            },
        },
        mt5_id => 'MTR1000',
    };

    $poa_status = 'verified';
    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes when POA=verified';

    $args = {
        loginid         => $client_cr->loginid,
        loginid_details => {
            MTR1000 => {
                attributes => {group => 'vanuatu'},
                status     => 'poa_failed',
            },
        },
    };

    $poa_status = 'verified';
    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes when POA=verified';

    # defined group, poa status is none
    # jurisdiction has limits
    # mt5 id status = poa_pending

    $args = {
        loginid              => $client_cr->loginid,
        new_mt5_jurisdiction => 'vanuatu',
        loginid_details      => {
            MTR1000 => {
                attributes => {group => 'vanuatu'},
                status     => 'poa_pending',
            },
        },
        mt5_id => 'MTR1000',
    };

    $poa_status = 'none';

    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes for POA none, jurisdiction has limits, status = poa_pending';

    # defined group, poa status is none
    # jurisdiction has limits
    # mt5 id status = poa_pending
    # mt5 real from jurisdiction status is null

    $args = {
        loginid              => $client_cr->loginid,
        new_mt5_jurisdiction => 'vanuatu',
        loginid_details      => {
            MTR1000 => {
                attributes => {group => 'vanuatu'},
                status     => 'poa_pending',
            },
            MTR1001 => {
                platform     => 'mt5',
                account_type => 'real',
                attributes   => {group => 'vanuatu'},
                status       => undef,
            },
        },
        mt5_id => 'MTR1000',
    };

    $poa_status = 'none';

    ok $rule_engine->apply_rules($rule_name, $args->%*),
        'Rule passes when jurisdiction has limits, status = poa_pending, mt5real sibling has undef status';

    # defined group, poa status is none
    # jurisdiction has limits
    # mt5 id status = poa_pending... ETC
    # accounts have been created now
    my $now = Date::Utility->new;

    for my $loginid_status (qw/poa_outdated poa_pending poa_rejected proof_failed verification_pending/) {
        $args = {
            loginid              => $client_cr->loginid,
            new_mt5_jurisdiction => 'vanuatu',
            loginid_details      => {
                MTR1000 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'vanuatu'},
                    status         => $loginid_status,
                    creation_stamp => $now->datetime_iso8601,
                },
                MTR1001 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'vanuatu'},
                    status         => $loginid_status,
                    creation_stamp => $now->datetime_iso8601,
                },
            },
            mt5_id => 'MTR1000',
        };

        $poa_status = 'none';

        ok $rule_engine->apply_rules($rule_name, $args->%*),
            "Rule passes for POA none, jurisdiction has limits, status = $loginid_status, accounts created now";
    }

    # defined group, poa status is none
    # jurisdiction has limits
    # mt5 id status = poa_pending... ETC
    # accounts have been created on the boundary of vanuatu (5 days)
    for my $loginid_status (qw/poa_outdated poa_pending poa_rejected proof_failed verification_pending/) {
        $args = {
            loginid              => $client_cr->loginid,
            new_mt5_jurisdiction => 'vanuatu',
            loginid_details      => {
                MTR1000 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'vanuatu'},
                    status         => $loginid_status,
                    creation_stamp => $now->minus_time_interval('5d')->datetime_iso8601,
                },
                MTR1001 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'vanuatu'},
                    status         => $loginid_status,
                    creation_stamp => $now->datetime_iso8601,
                },
            },
            mt5_id => 'MTR1000',
        };

        $poa_status = 'none';

        ok $rule_engine->apply_rules($rule_name, $args->%*),
            "Rule passes for POA none, jurisdiction has limits, status = $loginid_status, accounts created 5 days ago";
    }

    # defined group, poa status is none
    # jurisdiction has limits
    # mt5 id status = poa_pending... ETC
    # accounts have been created 6 days ago

    for my $loginid_status (qw/poa_outdated poa_pending poa_rejected proof_failed verification_pending/) {
        $args = {
            loginid              => $client_cr->loginid,
            new_mt5_jurisdiction => 'vanuatu',
            loginid_details      => {
                MTR1000 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'vanuatu'},
                    status         => $loginid_status,
                    creation_stamp => $now->minus_time_interval('6d')->datetime_iso8601,
                },
                MTR1001 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'vanuatu'},
                    status         => $loginid_status,
                    creation_stamp => $now->datetime_iso8601,
                },
            },
            mt5_id => 'MTR1000',
        };

        $poa_status = 'none';

        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, $args->%*) },
            {
                error_code => 'POAVerificationFailed',
                rule       => $rule_name,
                params     => {mt5_status => 'poa_failed'},
            },
            "POA Failed status = poa_failed, loginid status = $loginid_status"
        );
    }

    # defined group, poa status is none
    # jurisdiction has limits
    # mt5 id status = poa_pending...ETC
    # accounts have been created on the boundary of bvi (10 days)
    for my $loginid_status (qw/poa_outdated poa_pending poa_rejected proof_failed verification_pending/) {
        $args = {
            loginid              => $client_cr->loginid,
            new_mt5_jurisdiction => 'vanuatu',
            loginid_details      => {
                MTR1000 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'bvi'},
                    status         => $loginid_status,
                    creation_stamp => $now->minus_time_interval('5d')->datetime_iso8601,
                },
                MTR1001 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'bvi'},
                    status         => $loginid_status,
                    creation_stamp => $now->datetime_iso8601,
                },
            },
            mt5_id => 'MTR1000',
        };

        $poa_status = 'none';

        ok $rule_engine->apply_rules($rule_name, $args->%*),
            "Rule passes for POA none, jurisdiction has limits, status = $loginid_status, accounts created 5 days ago";
    }

    # defined group, poa status is none
    # jurisdiction has limits
    # mt5 id status = poa_pending...ETC
    # accounts have been created 11 days ago
    for my $loginid_status (qw/poa_outdated poa_pending poa_rejected proof_failed verification_pending/) {
        $args = {
            loginid              => $client_cr->loginid,
            new_mt5_jurisdiction => 'vanuatu',
            loginid_details      => {
                MTR1000 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'bvi'},
                    status         => $loginid_status,
                    creation_stamp => $now->minus_time_interval('11d')->datetime_iso8601,
                },
                MTR1001 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'bvi'},
                    status         => $loginid_status,
                    creation_stamp => $now->datetime_iso8601,
                },
            },
            mt5_id => 'MTR1000',
        };

        $poa_status = 'none';

        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, $args->%*) },
            {
                error_code => 'POAVerificationFailed',
                rule       => $rule_name,
                params     => {mt5_status => 'poa_failed'},
            },
            "POA Failed status = poa_failed, loginid stauts = $loginid_status"
        );
    }

    # defined group, poa status is none
    # jurisdiction has limits
    # mt5 id status = poa_pending...ETC
    # accounts have been created now
    # poi status is verified
    for my $loginid_status (qw/poa_outdated poa_pending poa_rejected proof_failed verification_pending/) {
        $args = {
            loginid              => $client_cr->loginid,
            new_mt5_jurisdiction => 'vanuatu',
            loginid_details      => {
                MTR1000 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'bvi'},
                    status         => $loginid_status,
                    creation_stamp => $now->datetime_iso8601,
                },
                MTR1001 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'bvi'},
                    status         => $loginid_status,
                    creation_stamp => $now->datetime_iso8601,
                },
            },
            mt5_id => 'MTR1000',
        };

        $poa_status = 'none';
        $poi_status = 'verified';

        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, $args->%*) },
            {
                error_code => 'POAVerificationFailed',
                rule       => $rule_name,
                params     => {mt5_status => 'poa_pending'},
            },
            "POA Failed status = poa_pending, loginid status = $loginid_status"
        );
    }

    # defined group, poa status is none
    # jurisdiction has limits
    # mt5 id status = poa_pending...ETC
    # accounts have been created now
    # poi status is not verified
    for my $loginid_status (qw/poa_outdated poa_pending poa_rejected proof_failed verification_pending/) {
        $args = {
            loginid              => $client_cr->loginid,
            new_mt5_jurisdiction => 'vanuatu',
            loginid_details      => {
                MTR1000 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'bvi'},
                    status         => $loginid_status,
                    creation_stamp => $now->datetime_iso8601,
                },
                MTR1001 => {
                    platform       => 'mt5',
                    account_type   => 'real',
                    attributes     => {group => 'bvi'},
                    status         => $loginid_status,
                    creation_stamp => $now->datetime_iso8601,
                },
            },
            mt5_id => 'MTR1000',
        };

        $poa_status = 'none';
        $poi_status = 'none';

        ok $rule_engine->apply_rules($rule_name, $args->%*),
            "Rule passes for POA none, jurisdiction has limits, status = $loginid_status, accounts created now, poi status not verified";
    }
};

$rule_name = 'mt5_account.account_proof_status_allowed';
subtest $rule_name => sub {

    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $poa_status  = 'none';
    my $poi_status  = 'none';

    $client_mock->mock(
        'get_poa_status',
        sub {
            return $poa_status;
        });
    $client_mock->mock(
        'get_poi_status',
        sub {
            return $poi_status;
        });
    $client_mock->mock(
        'get_poi_status_jurisdiction',
        sub {
            return $poi_status;
        });

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'mt5+poa+checks2@test.com',
    });

    BOM::User->create(
        email    => $client_cr->email,
        password => 'x',
    )->add_client($client_cr);

    $client_cr->account('USD');

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

    # undefined group

    my $args = {
        loginid         => $client_cr->loginid,
        loginid_details => {
            MTR1000 => {attributes => {group => undef}},
        },
        mt5_id => 'MTR1000',
    };

    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes for undefined group within a defined mt5 loginid';

    # defined group, jurisdiction without limits

    $args = {
        loginid         => $client_cr->loginid,
        loginid_details => {
            MTR1000 => {attributes => {group => undef}},
        },
        mt5_id => 'MTR1000',
    };

    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes for defined group, jurisdiction is undef';

    # defined group, poa status is none
    # jurisdiction has no proof requirements

    $args = {
        loginid         => $client_cr->loginid,
        loginid_details => {
            MTR1000 => {attributes => {group => 'TEST'}},
        },
        mt5_id => 'MTR1000',
    };

    ok $rule_engine->apply_rules($rule_name, $args->%*), 'Rule passes for POA none, jurisdiction is defined but has no proof requirements';

    # defined group, poa status is none
    # jurisdiction has proof requirements

    my %proof_requirements = +BOM::Rules::RuleRepository::MT5::JURISDICTION_PROOF_REQUIREMENT->%*;
    my $good_status        = [qw/verified/];
    my $pending_status     = [qw/pending/];
    my $bad_status         = [qw/expired none rejected suspected/];

    for my $lc (keys %proof_requirements) {
        my $required = +{map { $_ => 1 } $proof_requirements{$lc}->@*};

        $args = {
            loginid         => $client_cr->loginid,
            loginid_details => {
                MTR1000 => {attributes => {group => $lc}},
            },
            mt5_id => 'MTR1000',
        };

        if ($required->{poi}) {
            for my $status ($good_status->@*) {
                $poa_status = 'verified';
                $poi_status = $status;

                ok $rule_engine->apply_rules($rule_name, $args->%*), "LC=$lc poi=$poi_status poa=$poa_status, passes";
            }

            for my $status ($pending_status->@*) {
                $poa_status = 'verified';
                $poi_status = $status;

                cmp_deeply(
                    exception { $rule_engine->apply_rules($rule_name, $args->%*) },
                    {
                        error_code => 'ProofRequirementError',
                        rule       => $rule_name,
                        params     => {mt5_status => 'verification_pending'},
                    },
                    "LC=$lc poi=$poi_status poa=$poa_status, fails"
                );
            }

            for my $status ($bad_status->@*) {
                $poa_status = 'verified';
                $poi_status = $status;

                cmp_deeply(
                    exception { $rule_engine->apply_rules($rule_name, $args->%*) },
                    {
                        error_code => 'ProofRequirementError',
                        rule       => $rule_name,
                        params     => {mt5_status => 'proof_failed'},
                    },
                    "LC=$lc poi=$poi_status poa=$poa_status, fails"
                );
            }
        }

        if ($required->{poa}) {
            for my $status ($good_status->@*) {
                $poi_status = 'verified';
                $poa_status = $status;

                ok $rule_engine->apply_rules($rule_name, $args->%*), "LC=$lc poi=$poi_status poa=$poa_status, passes";
            }

            for my $status ($pending_status->@*) {
                $poi_status = 'verified';
                $poa_status = $status;

                cmp_deeply(
                    exception { $rule_engine->apply_rules($rule_name, $args->%*) },
                    {
                        error_code => 'ProofRequirementError',
                        rule       => $rule_name,
                        params     => {mt5_status => 'verification_pending'},
                    },
                    "LC=$lc poi=$poi_status poa=$poa_status, fails"
                );
            }

            for my $status ($bad_status->@*) {
                $poi_status = 'verified';
                $poa_status = $status;

                cmp_deeply(
                    exception { $rule_engine->apply_rules($rule_name, $args->%*) },
                    {
                        error_code => 'ProofRequirementError',
                        rule       => $rule_name,
                        params     => {mt5_status => 'proof_failed'},
                    },
                    "LC=$lc poi=$poi_status poa=$poa_status, fails"
                );
            }
        }
    }
};

subtest 'Vanuatu + IDV' => sub {
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'mt5+vanuatu_idv@test.com',
    });

    BOM::User->create(
        email    => $client_cr->email,
        password => 'x',
    )->add_client($client_cr);

    $client_cr->account('USD');

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);

    my $client_mock = Test::MockModule->new('BOM::User::Client');
    my $idv_status  = 'none';
    my $poa_status  = 'none';

    $client_mock->mock(
        'get_idv_status',
        sub {
            return $idv_status;
        });

    $client_mock->mock(
        'get_poa_status',
        sub {
            return $poa_status;
        });

    subtest 'new vanuatu account' => sub {
        my $args = {
            loginid              => $client_cr->loginid,
            new_mt5_jurisdiction => 'vanuatu',
            loginid_details      => {

            },
        };

        $idv_status = 'verified';

        cmp_deeply(
            exception { $rule_engine->apply_rules('mt5_account.account_poa_status_allowed', $args->%*) },
            {
                error_code => 'POAVerificationFailed',
                rule       => 'mt5_account.account_poa_status_allowed',
                params     => {mt5_status => 'poa_pending'}
            },
            "Vanuatu new account, POA is pending, IDV verified"
        );

        cmp_deeply(exception { $rule_engine->apply_rules('mt5_account.account_proof_status_allowed', $args->%*) },
            undef, "Vanuatu new account, POA is pending, IDV verified");

        $idv_status = 'none';

        cmp_deeply(exception { $rule_engine->apply_rules('mt5_account.account_poa_status_allowed', $args->%*) },
            undef, "Vanuatu new account, IDV = none");

        cmp_deeply(
            exception { $rule_engine->apply_rules('mt5_account.account_proof_status_allowed', $args->%*) },
            {
                error_code => 'ProofRequirementError',
                rule       => 'mt5_account.account_proof_status_allowed',
                params     => {mt5_status => 'proof_failed'}
            },
            "Vanuatu new account, IDV = none"
        );

    };

    subtest 'existing account check, status = undef' => sub {
        my $args = {
            loginid         => $client_cr->loginid,
            mt5_id          => 'MTR1000',
            loginid_details => {
                MTR1000 => {
                    attributes   => {group => 'vanuatu'},
                    status       => undef,
                    platform     => 'mt5',
                    account_type => 'real',
                    group        => 'vanuatu'
                },
            },
        };

        $idv_status = 'verified';

        cmp_deeply(exception { $rule_engine->apply_rules('mt5_account.account_poa_status_allowed', $args->%*) },
            undef, "Vanuatu existing account, POA is pending, IDV verified");

        cmp_deeply(exception { $rule_engine->apply_rules('mt5_account.account_proof_status_allowed', $args->%*) },
            undef, "Vanuatu existing account, POA is pending, IDV verified");

        $idv_status = 'none';

        cmp_deeply(exception { $rule_engine->apply_rules('mt5_account.account_poa_status_allowed', $args->%*) },
            undef, "Vanuatu existing account, IDV = none");

        cmp_deeply(
            exception { $rule_engine->apply_rules('mt5_account.account_proof_status_allowed', $args->%*) },
            {
                error_code => 'ProofRequirementError',
                rule       => 'mt5_account.account_proof_status_allowed',
                params     => {mt5_status => 'proof_failed'}
            },
            "Vanuatu existing account, IDV = none"
        );
    };

    subtest 'existing account check, status = not undef' => sub {
        my $args = {
            loginid         => $client_cr->loginid,
            mt5_id          => 'MTR1000',
            loginid_details => {
                MTR1000 => {
                    attributes   => {group => 'vanuatu'},
                    status       => 'verification_pending',
                    platform     => 'mt5',
                    account_type => 'real',
                    group        => 'vanuatu'
                },
            },
        };

        $idv_status = 'verified';

        cmp_deeply(
            exception { $rule_engine->apply_rules('mt5_account.account_poa_status_allowed', $args->%*) },
            {
                error_code => 'POAVerificationFailed',
                rule       => 'mt5_account.account_poa_status_allowed',
                params     => {mt5_status => 'poa_pending'}
            },
            "Vanuatu existing account, POA is pending, IDV verified"
        );

        cmp_deeply(exception { $rule_engine->apply_rules('mt5_account.account_proof_status_allowed', $args->%*) },
            undef, "Vanuatu existing account, POA is pending, IDV verified");

        $idv_status = 'none';

        cmp_deeply(exception { $rule_engine->apply_rules('mt5_account.account_poa_status_allowed', $args->%*) },
            undef, "Vanuatu existing account, IDV = none");

        cmp_deeply(
            exception { $rule_engine->apply_rules('mt5_account.account_proof_status_allowed', $args->%*) },
            {
                error_code => 'ProofRequirementError',
                rule       => 'mt5_account.account_proof_status_allowed',
                params     => {mt5_status => 'proof_failed'}
            },
            "Vanuatu existing account, IDV = none"
        );
    };

    subtest 'existing account check, status = not undef, POA = verified' => sub {
        my $args = {
            loginid         => $client_cr->loginid,
            mt5_id          => 'MTR1000',
            loginid_details => {
                MTR1000 => {
                    attributes   => {group => 'vanuatu'},
                    status       => 'verification_pending',
                    platform     => 'mt5',
                    account_type => 'real',
                    group        => 'vanuatu'
                },
            },
        };

        $idv_status = 'verified';
        $poa_status = 'verified';

        cmp_deeply(exception { $rule_engine->apply_rules('mt5_account.account_poa_status_allowed', $args->%*) },
            undef, "Vanuatu existing account, POA is verified, IDV verified");

        cmp_deeply(exception { $rule_engine->apply_rules('mt5_account.account_proof_status_allowed', $args->%*) },
            undef, "Vanuatu existing account, POA is verified, IDV verified");

        $idv_status = 'none';

        cmp_deeply(exception { $rule_engine->apply_rules('mt5_account.account_poa_status_allowed', $args->%*) },
            undef, "Vanuatu existing account, IDV = none");

        cmp_deeply(
            exception { $rule_engine->apply_rules('mt5_account.account_proof_status_allowed', $args->%*) },
            {
                error_code => 'ProofRequirementError',
                rule       => 'mt5_account.account_proof_status_allowed',
                params     => {mt5_status => 'proof_failed'}
            },
            ,
            "Vanuatu existing account, IDV = none"
        );
    };
};

done_testing();
