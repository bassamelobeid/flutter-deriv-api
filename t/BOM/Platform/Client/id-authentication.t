use Test::Most 'no_plan';
use Test::FailWarnings;
use Test::MockObject::Extends;
use Carp;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Client;

use BOM::Platform::Client::IDAuthentication;
{

    package IDAuthentication;
    our @ISA = qw(BOM::Platform::Client::IDAuthentication);

    sub _notify {
        my ($self, @info) = @_;
        push @{$self->{notifications}}, [@info];
    }
    sub notified { shift->{notifications} }
    sub requires_authentication { my $s = shift; $s->_needs_proveid or $s->_needs_checkid }
}

subtest 'Constructor' => sub {
    my $client = BOM::Platform::Client->new({loginid => 'VRTC1001'});

    my $v = new_ok('IDAuthentication', [client => $client]);

    subtest 'client returned by default _register_account' => sub {
        ok !$v->client->is_first_deposit_pending, 'is virtual, with no tracking of first deposit';
        ok !$v->requires_authentication, 'triggers no authentication';
    };
};

subtest 'No authentication for virtuals' => sub {
    my $c = BOM::Platform::Client->new({loginid => 'VRTC1001'});

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
            ok !$v->client->get_status('cashier_locked');
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
            ok $v->requires_authentication, '.. does not require authentication';
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
            ok $v->_needs_proveid, '.. requires proveid';
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
            $v->run_authentication;
            my @notif = @{$v->notified};
            is @notif, 1, 'sent one notification';
            like $notif[0][0], qr/SET TO CASHIER_LOCKED PENDING EMAIL REQUEST FOR ID/, 'notification is correct';
            ok !$v->client->client_fully_authenticated, 'client should not be fully authenticated';
            ok !$v->client->get_status('age_verification'), 'client should not be age verified';
            ok $v->client->get_status('cashier_locked'), 'client is now cashier_locked';
        };
        subtest 'for MX' => sub {
            my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MX',
                residence   => 'gb',
            });

            my $v = IDAuthentication->new(client => $c);
            Test::MockObject::Extends->new($v);
            $v->run_authentication;
            my @notif = @{$v->notified};
            is @notif, 2, 'sent 2 notifications';
            like $notif[0][0], qr/192_PROVEID_AUTH_FAILED/, 'notification is correct';
            like $notif[1][0], qr/SET TO CASHIER_LOCKED PENDING EMAIL REQUEST FOR ID/, 'notification is correct';
            ok !$v->client->client_fully_authenticated, 'client should not be fully authenticated';
            ok !$v->client->get_status('age_verification'), 'client should not be age verified';
            ok $v->client->get_status('cashier_locked'), 'client is now cashier_locked';
            }

    };

    subtest 'but no strict age verification' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        $v->run_authentication;

        ok !$v->client->client_fully_authenticated, 'client should not be fully authenticated';
        ok !$v->client->get_status('age_verification'), 'client should not be age verified';
        ok !$v->client->get_status('cashier_locked'),   'cashier not locked';
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

        $v->mock(-_fetch_proveid, sub { return {fully_authenticated => 1,
                                                age_verified => 1} });
        $v->run_authentication;
        my @notif = @{$v->notified};
        is @notif, 1, 'sent one notification';
        like $notif[0][0], qr/PASSED ON FIRST DEPOSIT/, 'notification is correct';
        ok $v->client->client_fully_authenticated, 'client is fully authenticated';
        ok !$v->client->get_status('cashier_locked'), 'cashier not locked';
    };

    subtest 'flagged' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);

        Test::MockObject::Extends->new($v);
        $v->mock(-_fetch_proveid, sub { return {age_verified => 1, matches => ['YADA']} });
        $v->run_authentication;
        my @notif = @{$v->notified};
        is @notif, 1, 'sent one notification';
        like $notif[0][0], qr/PASSED BUT CLIENT FLAGGED/, 'notification is correct';
        ok !$v->client->client_fully_authenticated, 'client not fully authenticated';
        ok $v->client->get_status('age_verification'), 'client is age verified';
        ok !$v->client->get_status('cashier_locked'), 'cashier not locked';
    };

    subtest 'director' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        Test::MockObject::Extends->new($v);

        $v->mock(-_fetch_proveid, sub { return {deny => 1} });
        $v->run_authentication;
        my @notif = @{$v->notified};
        is @notif, 2, 'sent one notification';
        like $notif[0][0], qr/192_PROVEID_AUTH_FAILED/, 'notification is correct';
        like $notif[1][0], qr/SET TO CASHIER_LOCKED PENDING EMAIL REQUEST FOR ID/, 'notification is correct';
        ok !$v->client->client_fully_authenticated, 'client not fully authenticated';
        ok !$v->client->get_status('age_verification'), 'client not age verified';
        ok $v->client->get_status('cashier_locked'), 'client now cashier_locked';
    };

    subtest 'age verified' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        Test::MockObject::Extends->new($v);
        $v->mock(-_fetch_proveid, sub { return {age_verified => 1} });
        $v->run_authentication;
        my @notif = @{$v->notified};
        is @notif, 1, 'sent one notification';
        like $notif[0][0], qr/PASSED ONLY AGE VERIFICATION/, 'notification is correct';
        ok !$v->client->client_fully_authenticated, 'client not fully authenticated';
        ok $v->client->get_status('age_verification'), 'client is age verified';
        ok !$v->client->get_status('cashier_locked'), 'cashier not locked';
    };

    # 'fallback to checkid' removed.. we don't fallback to checkid test anymore.

    subtest 'failed authentication' => sub {
        my $c = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
            residence   => 'ar',
        });

        my $v = IDAuthentication->new(client => $c);
        Test::MockObject::Extends->new($v);

        $v->mock(-_fetch_proveid, sub { return {} });
        $v->mock(-_fetch_checkid, sub { return });
        $v->run_authentication;
        my @notif = @{$v->notified};
        is @notif, 2, 'sent two notification';
        like $notif[0][0], qr/192_PROVEID_AUTH_FAILED/, 'first notification is correct';
        like $notif[1][0], qr/SET TO CASHIER_LOCKED PENDING EMAIL REQUEST FOR ID/, 'notification is correct';
        ok !$v->client->client_fully_authenticated, 'client not fully authenticated';
        ok !$v->client->get_status('age_verification'), 'client not age verified';
        ok $v->client->get_status('cashier_locked'), 'client now cashier_locked';
    };
};

