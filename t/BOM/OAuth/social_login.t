use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use Test::MockModule;
use BOM::Database::Model::OAuth;
use JSON::MaybeUTF8 qw(:v1);
use MIME::Base64    qw(encode_base64 decode_base64);
use BOM::OAuth::O;
use Data::Dumper;
use BOM::Platform::Context qw(localize);
use BOM::OAuth::Static     qw(get_message_mapping);
use Locale::Codes::Country qw( code2country );
use BOM::OAuth::SocialLoginController;

## init
my $app_id = do {
    my $oauth = BOM::Database::Model::OAuth->new;
    $oauth->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
    $oauth->dbic->dbh->do("DELETE FROM oauth.access_token");
    $oauth->dbic->dbh->do("DELETE FROM oauth.apps WHERE name='Test App'");
    my $app = $oauth->create_app({
        name         => 'Test App',
        user_id      => 1,
        scopes       => ['read', 'trade'],
        redirect_uri => 'https://www.example.com/'
    });
    $app->{app_id};
};

# Mock secure cookie session to false as http is used in tests.
my $mocked_cookie_session = Test::MockModule->new('Mojolicious::Sessions');
$mocked_cookie_session->mock(
    'secure' => sub {
        return 0;
    });

#mock #O
my $mock_oauth = Test::MockModule->new('BOM::OAuth::O');
my $use_oneall;
$mock_oauth->mock('_oneall_ff_web' => sub { return $use_oneall; });

my $use_oneall_mobile;
my $mock_social_controller = Test::MockModule->new('BOM::OAuth::SocialLoginController');
$mock_social_controller->mock(_use_oneall_mobile => sub { return $use_oneall_mobile; });

#mock SocialLoginClient
my $mock_sls = Test::MockModule->new('BOM::OAuth::SocialLoginClient');
$mock_sls->mock(
    get_providers => sub {
        return [{
                auth_url       => "dummy.com",
                name           => "google",
                nonce          => 'nonce',
                code_challenge => 'code_challenge',
                code_verifier  => 'code_verifier'
            }];
    });

#mock Mojo::Controller
my $mock_mojo      = Test::MockModule->new('Mojolicious::Controller');
my $signed_cookies = {};
$mock_mojo->mock(
    signed_cookie => sub {
        my ($self, $cookie_name, $cookie_data, $cookie_settings) = @_;
        $signed_cookies->{$cookie_name} = {
            data     => $cookie_data,
            settings => $cookie_settings
        };
        $mock_mojo->original('signed_cookie')->(@_);
    });
my $stash = {};
$mock_mojo->mock(
    stash => sub {
        my ($self, $key, $value) = @_;
        $stash->{$key} = $value if $key && $value;
        return $mock_mojo->original('stash')->(@_);
    });
my $sessions_hash = {};
$mock_mojo->mock(
    'session',
    sub {
        my $self = shift;

        my $stash = $self->stash;
        $self->app->sessions->load($self) unless exists $stash->{'mojo.active_session'};

        # Hash
        my $session = $stash->{'mojo.session'} ||= {};
        $sessions_hash = $session;
        return $session unless @_;

        # Get
        return $session->{$_[0]} unless @_ > 1 || ref $_[0];

        # Set
        my $values = ref $_[0] ? $_[0] : {@_};
        @$session{keys %$values} = values %$values;
        return $self;
    });

#mock config
my $mock_config = Test::MockModule->new('BOM::Config');
$mock_config->mock(
    service_social_login => sub {
        return {
            social_login => {
                port => 'dummy',
                host => 'dummy'
            }};
    });

my $t = Test::Mojo->new('BOM::OAuth');
subtest 'render social login based on feature flag' => sub {
    $use_oneall = 1;
    $t->get_ok("/authorize?app_id=$app_id")->element_exists('div[id="oa_social_login_container"]', 'oneall rendered')
        ->element_exists_not('a[href=dummy.com]', 'social login not rendered');

    $use_oneall = 0;
    $t->get_ok("/authorize?app_id=$app_id")->element_exists_not('div[id="oa_social_login_container"]', 'one all not rendered')
        ->element_exists('a[href=dummy.com]', 'social login rendered');

};

subtest 'render social login based on AB test feature flag' => sub {
    $use_oneall = 1;
    $t->get_ok("/authorize?app_id=$app_id&use_service=1")->element_exists_not('div[id="oa_social_login_container"]', 'one all not rendered')
        ->element_exists('a[href=dummy.com]', 'social login rendered');

    $use_oneall = 0;
    $t->get_ok("/authorize?app_id=$app_id&use_service=1")->element_exists_not('div[id="oa_social_login_container"]', 'one all not rendered')
        ->element_exists('a[href=dummy.com]', 'social login rendered');
};

subtest 'social login sign up' => sub {
    $use_oneall = 0;
    $t->get_ok("/authorize?app_id=$app_id&social_signup=google")->status_is(302, 'redirect in case of signup')->header_is(
        'location' => 'dummy.com',
        'correct redirect'
    );

    $t->get_ok("/authorize?app_id=$app_id&social_signup=github")->content_like('/invalid_request/', 'invalid request if provider does not exsit');
};

subtest 'setting up social login' => sub {
    $use_oneall = 0;
    $t->get_ok("/authorize?app_id=$app_id");
    is_deeply($stash->{social_login_links}, {google => 'dummy.com'}, 'providers urls stashed');
    ok defined $signed_cookies->{sls}, 'social login cookie exists';

    is_deeply(
        $signed_cookies->{sls}->{settings},
        {
            httponly => 1,
            secure   => 1,
            samesite => 'None'
        },
        'social login cookie settings are correct'
    );

    is_deeply(
        decode_json_utf8(decode_base64($signed_cookies->{sls}->{data})),
        {
            'query_params' => {'app_id' => $app_id},
            'google'       => {
                'nonce'          => 'nonce',
                'code_challenge' => 'code_challenge',
                'code_verifier'  => 'code_verifier'
            }
        },
        'social login cookie data are correct'
    );

    $mock_sls->unmock_all;
    my $error = "Social Login Service unavailable";
    $mock_sls->mock(get_providers => sub { die $error; });
    $t->get_ok("/authorize?app_id=$app_id")->status_is(200, 'survive social login service outage');
};

my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
my %emitted;
$mock_events->mock(
    'emit' => sub {
        my ($type, $data) = @_;
        $emitted{$type} //= [];
        push $emitted{$type}->@*, $data;
    });

subtest 'redirect scenaions' => sub {
    $use_oneall = 0;
    my $mock_helper = Test::MockModule->new('BOM::OAuth::Helper');
    my $sls_cookie;
    $mock_helper->mock(
        'get_social_login_cookie' => sub {
            return $sls_cookie;
        });
    my $test_data;
    $mock_sls->mock(
        'retrieve_user_info' => sub {
            my ($sls, $base_url, $exchage_params) = @_;
            return {
                email    => $test_data->{email},
                provider => $test_data->{provider}};
        });

    subtest 'signup social login service' => sub {
        $test_data  = get_test_data(app_id => $app_id);
        $sls_cookie = $test_data->{sls_cookie};
        set_residence($t, 'au');
        my $res = $t->get_ok("/social-login/callback/$test_data->{provider}?code=$test_data->{code}&state=$test_data->{state}");
        $res->status_is(302)->header_like('location' => qr{\/oauth2\/authorize\?app_id\=$app_id\&brand\=$test_data->{brand}});
        #user
        my $user = eval { BOM::User->new(email => $test_data->{email}) };
        ok $user, 'User was created';
        is $user->{app_id}, $app_id, 'User has correct app_id';
        ok $user->{has_social_signup}, 'User has social signup';

        #user connect
        my $user_connect  = BOM::Database::Model::UserConnect->new;
        my $provider_data = {
            user => {
                identity => {
                    provider              => $test_data->{provider},
                    provider_identity_uid => "sls_$test_data->{email}"
                }}};
        my $user_connect_id = $user_connect->get_user_id_by_connect($provider_data, $test_data->{email});
        is $user_connect_id, $user->{id}, 'User connected to the provider';

        #event
        ok $emitted{"signup"}, "signup event emitted";
        is $emitted{"signup"}->[0]->{properties}->{type},    'trading', 'track args type=trading';
        is $emitted{"signup"}->[0]->{properties}->{subtype}, 'virtual', 'track args subtype=virtual';

        #session
        is $sessions_hash->{'_sls_user_id'}, $user->{id}, ' _sls_user_id Session set';
        ok $sessions_hash->{'_is_social_signup'}, '_is_social_signup Session set';

        #redirect to outh
        my $mock_oauth = Test::MockModule->new('BOM::Database::Model::OAuth');
        $mock_oauth->mock('is_official_app' => sub { return 1; });
        $t->get_ok("/authorize?app_id=$app_id&brand=$test_data->{brand}")->status_is(302)->header_like(location => qr{https://www.example.com/});

        #session
        ok !$sessions_hash->{'_sls_user_id'}, 'Social session removed';
    };

    subtest 'signup/signin social login service multiple providers' => sub {
        $test_data  = get_test_data(app_id => $app_id);
        $sls_cookie = $test_data->{sls_cookie};

        #sign up.
        set_residence($t, 'au');
        my $res = $t->get_ok("/social-login/callback/$test_data->{provider}?code=$test_data->{code}&state=$test_data->{state}");
        $res->status_is(302)->header_like('location' => qr{\/oauth2\/authorize\?app_id\=$app_id\&brand\=$test_data->{brand}});

        #signin wirh different provider
        $test_data = get_test_data(
            app_id   => $app_id,
            provider => 'facebook',
            email    => $test_data->{email});
        $res = $t->get_ok("/social-login/callback/$test_data->{provider}?code=$test_data->{code}&state=$test_data->{state}");
        $res->status_is(302)->header_like('location' => qr{\/oauth2\/authorize\?app_id\=$app_id\&brand\=$test_data->{brand}});
        is $sessions_hash->{social_error}, localize(get_message_mapping()->{INVALID_PROVIDER}, 'Google'), 'correct social error';
    };

    subtest 'email/password vs social login service' => sub {
        $test_data = get_test_data(app_id => $app_id);

        #create email/pass user
        my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'CR',
                email       => $test_data->{email}});
        my $user = BOM::User->create(
            email    => $test_data->{email},
            password => 'test'
        );

        #sign in using sls.
        set_residence($t, 'au');
        my $res = $t->get_ok("/social-login/callback/$test_data->{provider}?code=$test_data->{code}&state=$test_data->{state}");
        $res->status_is(302)->header_like('location' => qr{\/oauth2\/authorize\?app_id\=$app_id\&brand\=$test_data->{brand}});

        is $sessions_hash->{social_error}, localize(get_message_mapping()->{NO_LOGIN_SIGNUP}), 'correct social error';
    };

    subtest 'invalid parameters' => sub {

        #invalid residence
        set_residence($t, 'my');
        $test_data  = get_test_data(app_id => $app_id);
        $sls_cookie = $test_data->{sls_cookie};
        my $res = $t->get_ok("/social-login/callback/$test_data->{provider}?code=$test_data->{code}&state=$test_data->{state}");
        $res->status_is(302)->header_like('location' => qr{\/oauth2\/authorize\?app_id\=$app_id\&brand\=$test_data->{brand}});
        is $sessions_hash->{social_error}, localize(get_message_mapping()->{INVALID_RESIDENCE}, code2country('my')),
            'correct social error for invalid residence';

        #invalid email
        set_residence($t, 'au');
        $test_data = get_test_data(
            app_id => $app_id,
            email  => 'invalid'
        );
        $res = $t->get_ok("/social-login/callback/$test_data->{provider}?code=$test_data->{code}&state=$test_data->{state}");
        $res->status_is(302)->header_like('location' => qr{\/oauth2\/authorize\?app_id\=$app_id\&brand\=$test_data->{brand}});
        is $sessions_hash->{social_error}, localize(get_message_mapping()->{INVALID_SOCIAL_EMAIL}, ucfirst($test_data->{provider})),
            'correct social error for invalid residence';
    };

    subtest 'OneAll integraion' => sub {
        # Mocking OneAll Data
        my $mocked_oneall = Test::MockModule->new('WWW::OneAll');
        $mocked_oneall->mock(
            new        => sub { bless +{}, 'WWW::OneAll' },
            connection => sub {
                return $test_data->{oneall};
            });

        subtest 'OneAll signup, social login signin' => sub {
            $test_data = get_test_data(app_id => $app_id);

            #singup using oneall
            $use_oneall = 1;
            set_residence($t, 'au');
            $t->get_ok("/oneall/callback?app_id=$app_id&connection_token=1")->status_is(302);
            my $user = eval { BOM::User->new(email => $test_data->{email}) };
            ok $user, 'User was created';
            is $sessions_hash->{_oneall_user_id}, $user->{id}, 'user session correct';

            #signin using sls
            $use_oneall = 0;
            my $res = $t->get_ok("/social-login/callback/$test_data->{provider}?code=$test_data->{code}&state=$test_data->{state}");
            $res->status_is(302)->header_like('location' => qr{\/oauth2\/authorize\?app_id\=$app_id\&brand\=$test_data->{brand}});
            is $sessions_hash->{_oneall_user_id}, $sessions_hash->{_sls_user_id}, 'sls user session correct';
        };

        subtest 'Social login signup, OneAll login' => sub {
            $test_data = get_test_data(app_id => $app_id);

            #signup using sls
            $use_oneall = 0;
            set_residence($t, 'au');
            my $res = $t->get_ok("/social-login/callback/$test_data->{provider}?code=$test_data->{code}&state=$test_data->{state}");
            $res->status_is(302)->header_like('location' => qr{\/oauth2\/authorize\?app_id\=$app_id\&brand\=$test_data->{brand}});
            my $user = eval { BOM::User->new(email => $test_data->{email}) };
            ok $user, 'User was created';
            is $sessions_hash->{_sls_user_id}, $user->{id}, 'sls user session correct';

            #signin using oneall
            $use_oneall = 1;
            $t->get_ok("/oneall/callback?app_id=$app_id&connection_token=1")->status_is(302);
            is $sessions_hash->{_oneall_user_id}, $sessions_hash->{_sls_user_id}, 'user session correct';
        };
    };
    $mock_sls->unmock('retrieve_user_info');
    $mock_helper->unmock_all;
};

subtest 'app_id redirect (mobile)' => sub {
    my $test_data = get_test_data(app_id => $app_id);
    my $res       = $t->get_ok("/social-login/callback/app/$app_id?code=$test_data->{code}&state=$test_data->{state}");
    $res->status_is(302)->header_like('location' => qr{example\.com\/})->header_like('location' => qr{$test_data->{code}})
        ->header_like('location' => qr{$test_data->{state}});
};

subtest 'invalid response from social login service' => sub {
    $use_oneall = 0;
    my $test_data   = get_test_data(app_id => $app_id);
    my $mock_helper = Test::MockModule->new('BOM::OAuth::Helper');
    $mock_helper->mock(
        'get_social_login_cookie' => sub {
            return $test_data->{sls_cookie};
        });
    my $mock_http = Test::MockModule->new('HTTP::Tiny');
    my $response;
    my $code;
    $mock_http->mock(
        request => sub {
            my (@params) = @_;
            return {
                status  => $code,
                content => ref $response ? encode_json_utf8($response) : $response
            };
        });

    #service error
    $code     = 500;
    $response = {error => 'service unavailable'};
    set_residence($t, 'au');
    my $res = $t->get_ok("/social-login/callback/$test_data->{provider}?code=$test_data->{code}&state=$test_data->{state}");
    $res->status_is(302)->header_like('location' => qr{\/oauth2\/authorize\?app_id\=$app_id\&brand\=$test_data->{brand}});
    is $sessions_hash->{social_error}, localize(get_message_mapping()->{NO_USER_IDENTITY}), 'correct social error for service unvailable';

    #bad request
    $code      = 400;
    $response  = {error => 'state mismatch'};
    $test_data = get_test_data(app_id => $app_id);

    set_residence($t, 'au');
    $res = $t->get_ok("/social-login/callback/$test_data->{provider}?code=$test_data->{code}&state=$test_data->{state}");
    $res->status_is(302)->header_like('location' => qr{\/oauth2\/authorize\?app_id\=$app_id\&brand\=$test_data->{brand}});
    is $sessions_hash->{social_error}, localize(get_message_mapping()->{NO_AUTHENTICATION}), 'correct social error for NO_AUTHENTICATION';
};

subtest 'Social Login Provider Bridge Endpoint Test via route redirection' => sub {
    my @params;
    my $data = [{
            auth_url       => "dummy.com",
            name           => "google",
            nonce          => 'nonce',
            code_challenge => 'code_challenge',
            code_verifier  => 'code_verifier'
        }];
    $mock_sls->mock(
        get_providers => sub {
            @params = @_;
            return $data;
        });

    $use_oneall_mobile = 1;
    $t->get_ok("/api/v1/social-login/providers/$app_id")->status_is(200)->json_is({data => []});

    $use_oneall_mobile = 0;
    $t->get_ok("/api/v1/social-login/providers/$app_id")->status_is(200)->json_is({data => $data});
    is $params[2], $app_id, 'Correct query param for app_id';
    $mock_sls->unmock('get_providers');
    $mock_sls->mock(
        get_providers => sub {
            die "Error";
        });
    $t->get_ok("/api/v1/social-login/providers/$app_id")->status_is(500)->json_has('/error_code', 'SERVER_ERROR');
};

subtest 'multi domain support' => sub {
    $use_oneall = 0;
    my (@sls_providers_params, @sls_user_info_params);
    $mock_sls->mock(
        'get_providers' => sub {
            @sls_providers_params = @_;
        },
        'retrieve_user_info' => sub {
            @sls_user_info_params = @_;
        });
    $t->get_ok("/authorize?app_id=$app_id");
    like $sls_providers_params[1], qr{127.0.0.1}, 'base url is correct in providers request';

    $t->get_ok("/social-login/callback/provider?code=123&state=123");
    like $sls_user_info_params[1], qr{127.0.0.1}, 'base url is correct in user info request';

    $t->get_ok("/api/v1/social-login/providers/$app_id");
    like $sls_providers_params[1], qr{127.0.0.1}, 'base url is correct in providers api request';
};

#Helper functions

sub get_test_data {
    my %args = @_;

    my $samples = {};
    $samples->{state}          = 'random_state';
    $samples->{code}           = 'random_code';
    $samples->{nonce}          = 'random_nonce';
    $samples->{code_verifier}  = 'random_code_verifier';
    $samples->{code_challenge} = 'random_code_challenge';
    $samples->{provider}       = $args{provider} // 'google';
    $samples->{brand}          = $args{brand}    // 'deriv';
    $samples->{email}          = $args{email}    // 'test' . rand(999) . '@deriv.com';
    $samples->{sls_cookie}     = {
        query_params => {
            brand  => $samples->{brand},
            app_id => $args{app_id}
        },
        $samples->{provider} => {
            state          => $samples->{state},
            code           => $samples->{code},
            nonce          => $samples->{nonce},
            code_verifier  => $samples->{code_verifier},
            code_challenge => $samples->{code_challenge},
        }};
    $samples->{request_params} = {
        provider        => $samples->{provider},
        provider_params => {
            state          => $samples->{state},
            code_challenge => $samples->{code_challenge},
            nonce          => $samples->{nonce},
            code           => $samples->{code},
            code_verifier  => $samples->{code_verifier}
        },
        callback_params => {
            state => $samples->{state},
            code  => $samples->{code}}};
    $samples->{exchange_params} = {
        provider_name => $samples->{provider},
        uri_params    => {
            auth_code => $samples->{code},
            uri_state => $samples->{state}
        },
        cookie_params => {
            nonce         => $samples->{nonce},
            state         => $samples->{state},
            code_verifier => $samples->{code_verifier}}};
    $samples->{oneall} = {
        response => {
            request => {
                status => {
                    code => 200,
                },
            },
            result => {
                status => {
                    code => 200,
                    flag => '',
                },
                data => {
                    user => {
                        identity => {
                            emails                => [{value => $samples->{email}}],
                            provider              => $samples->{provider},
                            provider_identity_uid => 'test_uid',
                        }
                    },
                },
            },
        },
    };
    return $samples;
}

sub set_residence {
    my ($t, $residence) = @_;
    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });

}

done_testing();

1;
