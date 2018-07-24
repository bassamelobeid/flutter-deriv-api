use Test::Most 'no_plan';
use Test::FailWarnings;
use Test::MockObject::Extends;
use Carp;
use File::Spec;

use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::Platform::Client::IDAuthentication;
{

    package IDAuthentication;
    our @ISA = qw(BOM::Platform::Client::IDAuthentication);

    sub _notify {
        my ($self, @info) = @_;
        push @{$self->{notifications}}, [@info];
    }
    sub notified { shift->{notifications} }
    sub requires_authentication { my $s = shift; $s->client->landing_company->country eq 'Isle of Man' }
}

subtest 'Constructor' => sub {
    my $client = BOM::User::Client->new({loginid => 'VRTC1001'});

    my $v = new_ok('IDAuthentication', [client => $client]);

    subtest 'client returned by default _register_account' => sub {
        ok !$v->client->is_first_deposit_pending, 'is virtual, with no tracking of first deposit';
        ok !$v->requires_authentication, 'triggers no authentication';
    };
};

subtest 'No authentication for virtuals' => sub {
    my $c = BOM::User::Client->new({loginid => 'VRTC1001'});

    my $v = IDAuthentication->new(client => $c);
    ok !$v->client->is_first_deposit_pending, 'no tracking of first deposit';
    ok !$v->requires_authentication, '.. no authentication required';
};

subtest "No authentication for CR clients" => sub {
    for my $residence (qw(at au br gb ru se sg)) {
        subtest "resident of $residence" => sub {
            my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                residence   => $residence,
            });

            my $v = IDAuthentication->new(client => $c);
            ok $v->client->is_first_deposit_pending, 'real client awaiting first deposit';
            ok !$v->requires_authentication, '.. no authentication required';
            $v->run_authentication;
            ok !$v->client->status->get('cashier_locked');
        };
    }
};

subtest 'MLT clients' => sub {
    for my $residence (qw(gb)) {
        subtest "resident of $residence" => sub {
            my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MLT',
                residence   => $residence,
            });

            my $v = IDAuthentication->new(client => $c);
            ok $v->client->is_first_deposit_pending, 'real client awaiting first deposit';
            ok !$v->requires_authentication, '.. does not require authentication';
            }
    }

    # Non residents of supported countries should not require auth
    for my $residence (qw(al br de ru)) {
        subtest "resident of $residence" => sub {
            my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MLT',
                residence   => $residence,
            });

            my $v = IDAuthentication->new(client => $c);
            ok $v->client->is_first_deposit_pending, 'real client awaiting first deposit';
            ok !$v->requires_authentication, '.. no authentication required';
            }
    }
};

subtest 'MX clients' => sub {
    for my $residence (qw(al at au br de gb iom ru se)) {
        subtest "resident of $residence" => sub {
            my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MX',
                residence   => $residence,
            });

            my $v = IDAuthentication->new(client => $c);
            ok $v->client->is_first_deposit_pending, 'real client awaiting first deposit';
            ok $v->requires_authentication, '.. requires proveid';
            }
    }
};

subtest 'When auth not required' => sub {
    subtest 'and strict age verification' => sub {
        subtest 'for MLT' => sub {
            my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MLT',
                residence   => 'br',
            });

            my $v = IDAuthentication->new(client => $c);
            Test::MockObject::Extends->new($v);
            do {
                local $ENV{BOM_SUPPRESS_WARNINGS} = 1;
                $v->run_authentication;
            };
            ok !$v->client->fully_authenticated, 'client should not be fully authenticated';
            ok !$v->client->status->get('age_verification'), 'client should not be age verified';
            ok !$v->client->status->get('unwelcome'),        'client is not unwelcome';
            ok $v->client->status->get('cashier_locked'), 'client is now cashier_locked';
        };
        subtest 'for MX' => sub {
            my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MX',
                residence   => 'gb',
            });

            my $v = IDAuthentication->new(client => $c);
            Test::MockObject::Extends->new($v);

            $v->mock(
                -_fetch_proveid,
                sub {
                    return {kyc_summary_score => 1};
                });

            do {
                local $ENV{BOM_SUPPRESS_WARNINGS} = 1;
                $v->run_authentication;
            };
            ok !$v->client->fully_authenticated, 'client should not be fully authenticated';
            ok !$v->client->status->get('age_verification'), 'client should not be age verified';
            ok $v->client->status->get('unwelcome'), 'client is now unwelcome';
            }

    };

    subtest 'but no strict age verification' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        $v->run_authentication;

        ok !$v->client->fully_authenticated, 'client should not be fully authenticated';
        ok !$v->client->status->get('age_verification'), 'client should not be age verified';
        ok !$v->client->status->get('cashier_locked'),   'cashier not locked';
    };
};

subtest 'proveid' => sub {
    subtest 'fully authenticated' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        Test::MockObject::Extends->new($v);

        $v->mock(
            -_fetch_proveid,
            sub {
                return {
                    fully_authenticated => 1,
                    kyc_summary_score   => 3
                };
            });
        $v->run_authentication;
        is $v->notified, undef, 'sent zero notification';
        ok $v->client->status->get('age_verification'), 'client is age verified';
        ok !$v->client->status->get('cashier_locked'), 'cashier not locked';
    };

    subtest 'actual response from experian' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        Test::MockObject::Extends->new($v);

        $v->mock(
            -_fetch_proveid,
            sub {
                return {
                    kyc_summary_score   => 4,
                    num_verifications   => '2',
                    matches             => [],
                    fully_authenticated => 1
                };
            });

        $v->run_authentication;
        ok $v->client->status->get('age_verification'), 'client is age verified';
        ok !$v->client->status->get('cashier_locked'), 'cashier not locked';
    };

    subtest 'kyc 2 or less' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        Test::MockObject::Extends->new($v);

        $v->mock(
            -_fetch_proveid,
            sub {
                return {kyc_summary_score => 1};
            });

        $v->run_authentication;
        ok $v->client->status->get('unwelcome'), 'client is unwelcome';
        ok !$v->client->status->get('cashier_locked'), 'cashier not locked';
    };

    subtest 'kyc more than 2' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        Test::MockObject::Extends->new($v);

        $v->mock(
            -_fetch_proveid,
            sub {
                return {kyc_summary_score => 3};
            });
        $v->run_authentication;
        ok $v->client->status->get('age_verification'), 'client is age verified';
        ok !$v->client->status->get('cashier_locked'), 'cashier not locked';
    };

    subtest 'flagged' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);

        Test::MockObject::Extends->new($v);

        $v->mock(-_fetch_proveid, sub { return {kyc_summary_score => 3, matches => ['PEP']} });

        $v->run_authentication;
        my @notif = @{$v->notified};
        is @notif, 1, 'sent two notifications';
        like $notif[0][0], qr/PEP match/, 'notification is correct';
        ok $v->client->status->get('disabled'), 'client is disabled';
    };

    subtest 'deny' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        Test::MockObject::Extends->new($v);

        $v->mock(
            -_fetch_proveid,
            sub {
                return {
                    deny              => 1,
                    kyc_summary_score => 0
                };
            });
        do {
            local $ENV{BOM_SUPPRESS_WARNINGS} = 1;
            $v->run_authentication;
        };
        ok !$v->client->fully_authenticated, 'client not fully authenticated';
        ok !$v->client->status->get('age_verification'), 'client not age verified';
        ok $v->client->status->get('unwelcome'), 'client now unwelcome';
    };

    subtest 'Director/CCJ' => sub {
        my $types = {
            Directors => {matches => [qw/Directors/]},
            CCJ       => {CCJ     => 1},
        };
        foreach my $type (sort keys %$types) {
            my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MX',
                residence   => 'ar',
            });

            my $v = IDAuthentication->new(client => $c);
            Test::MockObject::Extends->new($v);

            $v->mock(
                -_fetch_proveid,
                sub {
                    return {
                        matches           => [qw/Directors/],
                        CCJ               => 1,
                        kyc_summary_score => 0
                    };
                });
            do {
                local $ENV{BOM_SUPPRESS_WARNINGS} = 1;
                $v->run_authentication;
            };
            ok !$v->client->fully_authenticated, 'client not fully authenticated: ' . $type;
            ok !$v->client->status->get('age_verification'), 'client not age verified: ' . $type;
        }
    };

    subtest 'age verified' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        Test::MockObject::Extends->new($v);
        $v->mock(-_fetch_proveid, sub { return {kyc_summary_score => 3} });
        $v->run_authentication;
        is $v->notified, undef, 'sent zero notification';
        ok !$v->client->fully_authenticated, 'client not fully authenticated';
        ok $v->client->status->get('age_verification'), 'client is age verified';
        ok !$v->client->status->get('cashier_locked'), 'cashier not locked';
    };

    subtest 'failed authentication' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        Test::MockObject::Extends->new($v);

        $v->mock(-_fetch_proveid, sub { return {kyc_summary_score => 0} });
        do {
            local $ENV{BOM_SUPPRESS_WARNINGS} = 1;
            $v->run_authentication;
        };
        ok !$v->client->fully_authenticated, 'client not fully authenticated';
        ok !$v->client->status->get('age_verification'), 'client not age verified';
        ok $v->client->status->get('unwelcome'), 'client now unwelcome';
    };
};

