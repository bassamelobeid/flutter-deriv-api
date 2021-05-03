package t::BOM::OAuth::OneAll;

use Mojolicious::Lite;
use Test::More;
use Test::Mojo;
use Brands;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::Request;
use BOM::OAuth::Common;
use BOM::Platform::Context qw(localize);
use BOM::OAuth::Static qw(get_message_mapping);
use Locale::Codes::Country qw(code2country);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::User;
use BOM::Platform::Event::Emitter;
use Test::MockModule;

get '/callback' => sub {
    my $c = shift;

    my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => $c->req});
    BOM::Platform::Context::request($request);
    $c->stash(request => $request);

    my $email         = $c->param('email');
    my $brand         = $c->param('brand') || 'binary';
    my $residence     = $c->stash('request')->country_code;
    my $signup_device = $c->param('signup_device');

    my $user_details = {
        email         => $email,
        brand         => $brand,
        residence     => $residence,
        signup_device => $signup_device,
    };
    my $utm_data = {
        utm_term     => "utm_term test",
        utm_msclk_id => 756,
    };
    my $account = BOM::OAuth::Common::create_virtual_account($user_details, $utm_data);

    if ($account->{error}) {
        if ($account->{error}->{code} eq 'invalid residence') {
            $c->render(json => {'error' => localize(get_message_mapping()->{INVALID_RESIDENCE}, code2country($residence))});
        } else {
            $c->render(json => {'error' => localize(get_message_mapping()->{$account->{error}->{code}})});
        }
    } else {
        my @clients = $account->{user}->clients();
        $c->render(
            json => {
                'residence'     => $clients[0]->residence,
                'signup_device' => $account->{user}->{signup_device}});
    }

    #$c->render(text => $clients[0]->residence);
};

my $t;
subtest "check wether client's country of residence is set correctly" => sub {
    $t = Test::Mojo->new('t::BOM::OAuth::OneAll');
    my ($signup_device, $residence, $email, $brand);

    #Test case 1: valid residence
    $signup_device = 'mobile';
    $residence     = 'au';
    $email         = 'test' . rand(999) . '@binary.com';
    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });

    $t->get_ok("/callback?email=$email&signup_device=$signup_device")->status_is(200)->json_is(
        json => {
            'residence'     => $residence,
            'signup_device' => $signup_device
        });

    #Test case 2: already registered user (email)
    $residence = 'es';
    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });
    $t->get_ok("/callback?email=$email")->status_is(200)->json_is(json => {'error' => localize(get_message_mapping()->{'duplicate email'})});

    #Test case 3: invalid (restricted) residence
    $residence = 'my';
    $email     = 'test' . rand(999) . '@binary.com';
    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });
    $t->get_ok("/callback?email=$email")->status_is(200)
        ->json_is(json => {'error' => localize(get_message_mapping()->{INVALID_RESIDENCE}, code2country($residence))});

    #Test case 4: invalid brand
    $residence = 'de';
    $email     = 'test' . rand(999) . '@binary.com';
    $brand     = 'invalid';
    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });
    $t->get_ok("/callback?email=$email&brand=$brand")->status_is(200)
        ->json_is(json => {'error' => localize(get_message_mapping()->{'InvalidBrand'})});

    #Test case 5: invalid signup device type
    $email         = 'test' . rand(999) . '@binary.com';
    $brand         = 'binary';
    $signup_device = 'Desktuup';

    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });
    $t->get_ok("/callback?email=$email&brand=$brand&signup_device=$signup_device")->status_is(200)->json_is(
        json => {
            'residence'     => $residence,
            'signup_device' => undef
        });
};

subtest "User sing up with social login, app_id is saved" => sub {
    my $t = Test::Mojo->new('BOM::OAuth');

    my $app_id = do {
        my $oauth = BOM::Database::Model::OAuth->new;
        my $app   = $oauth->create_app({
            name         => 'Test App',
            user_id      => 1,
            scopes       => ['read', 'trade', 'admin'],
            redirect_uri => 'https://www.example.com/'
        });
        $app->{app_id};
    };

    # mock domain_name to suppress warnings
    my $mocked_request = Test::MockModule->new('BOM::Platform::Context::Request');
    $mocked_request->mock('domain_name', 'www.binaryqa.com');

    my $email = 'test1' . rand(999) . '@binary.com';

    # Mocking OneAll Data
    my $mocked_oneall = Test::MockModule->new('WWW::OneAll');
    $mocked_oneall->mock(
        new        => sub { bless +{}, 'WWW::OneAll' },
        connection => sub {
            return +{
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
                                    emails                => [{value => $email}],
                                    provider              => 'google',
                                    provider_identity_uid => 'test_uid',
                                }
                            },
                        },
                    },
                },
            };
        });

    my $residence = 'au';
    $t->ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            $tx->req->headers->header('X-Client-Country' => $residence);
        });

    my %emitted;
    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->mock(
        'emit',
        sub {
            my ($type, $data) = @_;
            $emitted{$type}++;
        });

    $t->get_ok("/oneall/callback?app_id=$app_id&connection_token=1")->status_is(302);

    my $user = eval { BOM::User->new(email => $email) };
    ok $user, 'User was created';
    is $user->{app_id}, $app_id, 'User has correct app_id';

    ok $emitted{"signup"}, "signup event emitted";
};

done_testing();

1;
