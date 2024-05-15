use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Mojo;
use Test::MockModule;
use Test::MockObject;

use BOM::OAuth::SessionStore;

use Data::Dumper;

sub mock_c {
    my $c = Test::MockObject->new;
    $c->{stash} = {};
    $c->mock(
        signed_cookie => sub {
            my ($self, $cookie_name, $cookie_data, $cookie_settings) = @_;
            return $c->{stash}->{signed_cookies}->{$cookie_name} = {
                data     => $cookie_data,
                settings => $cookie_settings
            } if defined $cookie_data;

            return $c->{stash}->{signed_cookies}->{$cookie_name}->{data};
        });

    return $c;
}

sub create_session_store {
    my $c             = mock_c();
    my $session_store = BOM::OAuth::SessionStore->new(c => $c);
    return ($c, $session_store);
}

subtest 'app_ids' => sub {
    my ($c, $session_store) = create_session_store();
    is_deeply($session_store->app_ids, [], 'app_ids returns empty array when no session is set');

    $session_store->set_session('app_id', 'session_data');
    is_deeply($session_store->app_ids, ['app_id'], 'app_ids returns the app id when a session is set');
};

subtest 'set_session with string' => sub {
    my ($c, $session_store) = create_session_store();

    $session_store->set_session('app_id2', ['key1', 'value1', 'key2', 'value2']);
    is_deeply($session_store->app_ids, ['app_id2'], 'set_session sets the session data with array');
};

subtest 'store_session' => sub {
    my ($c, $session_store) = create_session_store();

    $session_store->set_session('123', ['key', 'value']);
    my $expire_at = time + 60 * 60 * 24 * 60;
    $session_store->store_session({is_new => 1});

    ok(exists $c->{stash}->{signed_cookies}->{_osid}, 'official session is set in the session data');
    is_deeply(
        $c->{stash}->{signed_cookies}->{_osid}->{settings},
        {
            httponly => 1,
            secure   => 1,
            expires  => $expire_at,
        },
        'official session settings is set correctly'
    );

    ok(exists $c->{stash}->{signed_cookies}->{_osid_123}, 'official session for app_id is set in the session data');
    is_deeply(
        $c->{stash}->{signed_cookies}->{_osid_123}->{settings},
        {
            httponly => 1,
            secure   => 1,
            expires  => $expire_at,
        },
        'official session for app_id settings is set correctly'
    );

};

subtest 'load_session' => sub {
    my ($c, $session_store) = create_session_store();

    subtest 'no signed_cookie found' => sub {
        $session_store->load_session();
        is_deeply($session_store->app_ids, [], 'app_ids returns empty array when no session is set');
    };

    subtest 'load session when signed_cookie found' => sub {
        # Set the session data
        $session_store->set_session('123', ['key', 'value']);
        $session_store->store_session({is_new => 1});

        my $new_session_store = BOM::OAuth::SessionStore->new(c => $c);
        is_deeply($new_session_store->app_ids, ['123'], 'app_ids returns empty array when no session is set');
    };
};

subtest 'Test get_session_for_app' => sub {
    my ($c, $session_store) = create_session_store();
    my $app_id  = '111';
    my $clients = ['acct1', 'acct2'];
    my $session = {
        acct1 => 'value',
        acct2 => 'value'
    };

    subtest 'Return session when num of accounts is the same as the sored session' => sub {
        $session_store->set_session($app_id, $session);
        my %result = $session_store->get_session_for_app($app_id, $clients);
        is_deeply(\%result, $session, 'Matching clients');
    };

    subtest 'Should not return session when num of accounts is more than the sored session' => sub {
        $session_store->set_session($app_id, $session);
        $clients = ['acct1', 'acct2', 'acct3'];
        my @result = $session_store->get_session_for_app($app_id, $clients);
        is_deeply(\@result, [], 'Return empty Arr if a new account was created');
    };
};

subtest 'clear_session' => sub {
    my ($c, $session_store) = create_session_store();

    $session_store->set_session('123', ['key', 'value']);
    my $expire_at = time + 60 * 60 * 24 * 60;
    $session_store->store_session({is_new => 1});

    ok(exists $c->{stash}->{signed_cookies}->{_osid}, 'official session is set in the session data');
    is_deeply(
        $c->{stash}->{signed_cookies}->{_osid}->{settings},
        {
            httponly => 1,
            secure   => 1,
            expires  => $expire_at,
        },
        'official session settings is set correctly'
    );

    ok(exists $c->{stash}->{signed_cookies}->{_osid_123}, 'official session for app_id is set in the session data');
    is_deeply(
        $c->{stash}->{signed_cookies}->{_osid_123}->{settings},
        {
            httponly => 1,
            secure   => 1,
            expires  => $expire_at,
        },
        'official session for app_id settings is set correctly'
    );

    $session_store->clear_session();

    is_deeply(
        $c->{stash}->{signed_cookies}->{_osid}->{settings},
        {
            expires => 1,
        },
        'official session Have been cleared'
    );

    is_deeply(
        $c->{stash}->{signed_cookies}->{_osid_123}->{settings},
        {
            expires => 1,
        },
        'official session for app_id Have been cleared'
    );
};

subtest 'is_valid_session' => sub {
    my ($c, $session_store) = create_session_store();

    my $mocked_oauth = Test::MockModule->new('BOM::Database::Model::OAuth');
    subtest 'Return false when no session is set' => sub {
        $mocked_oauth->mock(
            'get_token_details',
            sub {
                return {loginid => 'user123'};
            });
        is($session_store->is_valid_session, 0, 'is_valid_session returns false when no session is set');
    };

    subtest 'Return true when session is set with valid tokens' => sub {
        $session_store->set_session('123', ['key', 'token']);
        $session_store->store_session({is_new => 1});
        is($session_store->is_valid_session, 1, 'is_valid_session returns true when session is set');
    };

    subtest 'Return false when a token dose not exist anymore' => sub {
        $mocked_oauth->mock(
            'get_token_details',
            sub {
                return;
            });
        $session_store->set_session('123', ['key', 'token']);
        $session_store->store_session({is_new => 1});
        is($session_store->is_valid_session, 0, 'is_valid_session returns false when session is set');
    };
};

subtest 'get_loginid' => sub {
    my ($c, $session_store) = create_session_store();
    my $mocked_oauth = Test::MockModule->new('BOM::Database::Model::OAuth');
    $mocked_oauth->mock(
        'get_token_details',
        sub {
            return {loginid => 'user123'};
        });

    $session_store->set_session('123', ['key', 'token']);
    $session_store->store_session({is_new => 1});
    is($session_store->is_valid_session, 1, 'is_valid_session returns true when no session is set');

    is($session_store->get_loginid, 'user123', 'get_loginid returns the loginid');
};

subtest 'has_session' => sub {
    my ($c, $session_store) = create_session_store();
    is($session_store->has_session, '', 'has_session returns false when no session is set');

    $session_store->set_session('123', ['key', 'token']);
    $session_store->store_session({is_new => 1});
    is($session_store->has_session, 1, 'has_session returns true when session is set');
};

done_testing();

