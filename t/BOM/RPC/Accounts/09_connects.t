use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/create_test_user/;
use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::System::Config;
use WWW::OneAll;
use BOM::RPC::v3::Accounts;

my $client = create_test_user();

my $module = Test::MockModule->new('WWW::OneAll');
$module->mock('connection', sub { return sample_oneall_data() });
my $module2 = Test::MockModule->new('BOM::System::Config');
$module2->mock(
    'third_party',
    sub {
        return +{
            oneall => {
                public_key  => 'public_key',
                private_key => 'private_key'
            }};
    });

my $res = BOM::RPC::v3::Accounts::connect_add({
    client => $client,
    args   => {connection_token => 'mock'},
});
ok $res->{status}, 'connect_add';

$res = BOM::RPC::v3::Accounts::connect_list({
    client => $client,
});
is_deeply $res, ['google'], 'connect_list ok';

$res = BOM::RPC::v3::Accounts::connect_del({
    client => $client,
    args   => {provider => 'google'},
});
ok $res->{status}, 'connect_del';

$res = BOM::RPC::v3::Accounts::connect_list({
    client => $client,
});
is_deeply $res, [], 'connect_list ok';

done_testing();

sub sample_oneall_data {
    return {
        'response' => {
            'request' => {
                'resource' => '/connection/4dbadf81-f148-4ed5-b30f-4a6977edbfa7.json',
                'status'   => {
                    'info' => 'Your request has been processed successfully',
                    'flag' => 'success',
                    'code' => '200'
                },
                'date' => 'Wed, 13 Jul 2016 12:10:27 +0200'
            },
            'result' => {
                'status' => {
                    'info' => 'The user successfully authenticated',
                    'flag' => 'success',
                    'code' => '200'
                },
                'data' => {
                    'plugin' => {
                        'data' => {
                            'status'    => 'success',
                            'reason'    => 'user_authenticated',
                            'action'    => 'login',
                            'operation' => 'user_profile_read'
                        },
                        'key' => 'social_login'
                    },
                    'connection' => {
                        'date_creation'    => 'Wed, 13 Jul 2016 12:10:12 +0200',
                        'connection_token' => '4dbadf81-f148-4ed5-b30f-4a6977edbfa7',
                        'status'           => 'succeeded',
                        'callback_uri'     => 'http://www.binaryqa16.com/oauth2/oneall/callback?app_id=1'
                    },
                    'user' => {
                        'user_token' => '49f5354c-c091-4cd1-9f3d-72bbb76b6dd0',
                        'identity'   => {
                            'photos' => [{
                                    'value' => 'https://lh3.googleusercontent.com/-XdUIqdMkCWA/AAAAAAAAAAI/AAAAAAAAAAA/4252rscbv5M/photo.jpg?sz=50',
                                    'size'  => '5:L'
                                }
                            ],
                            'source' => {
                                'refresh_token' => {'key' => '1/2tS6sjQrYlVjHElqZ54_9U3zOgD_zDbnDGXlQe0XZRA'},
                                'access_token'  => {
                                    'date_expiration' => '07/13/2016 13:10:21',
                                    'key'             => 'ya29.CjAfA-pJvRhBnuxqc-UZhy6is0J7Kf1w1U0D2dsuOeZQUb1sU1NRfi6ZIyR8WmQoq7I'
                                },
                                'name' => 'Google',
                                'key'  => 'google'
                            },
                            'provider' => 'google',
                            'browser'  => {
                                'version' => {
                                    'full'  => '47.0',
                                    'major' => '47'
                                },
                                'agent'    => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.11; rv:47.0) Gecko/20100101 Firefox/47.0',
                                'platform' => {
                                    'name' => 'Macintosh',
                                    'type' => 'Desktop'
                                },
                                'type' => 'Firefox'
                            },
                            'urls' => [{
                                    'value' => 'https://plus.google.com/112382627336328685874',
                                    'type'  => 'profile'
                                }
                            ],
                            'date_creation'     => 'Wed, 29 Jun 2016 13:55:04 +0200',
                            'preferredUsername' => 'Fayland Lam',
                            'pictureUrl' => 'https://lh3.googleusercontent.com/-XdUIqdMkCWA/AAAAAAAAAAI/AAAAAAAAAAA/4252rscbv5M/photo.jpg?sz=50',
                            'id'         => 'https://plus.google.com/112382627336328685874',
                            'accounts'   => [{
                                    'domain' => 'google.com',
                                    'userid' => '112382627336328685874'
                                }
                            ],
                            'displayName'      => 'Fayland Lam',
                            'date_last_update' => 'Wed, 13 Jul 2016 12:10:22 +0200',
                            'name'             => {
                                'formatted'  => 'Fayland Lam',
                                'familyName' => 'Lam',
                                'givenName'  => 'Fayland'
                            },
                            'identity_token'        => 'c57bc496-a0d2-4426-a0e1-596ae6db40ad',
                            'provider_identity_uid' => 'PIUE74DCA7D9BDE86F517BB6401BCAF3209',
                            'emails'                => [{
                                    'value'       => 'fayland@regentmarkets.com',
                                    'is_verified' => bless(do { \(my $o = 1) }, 'JSON::PP::Boolean')}]
                        },
                        'identities' => [{
                                'provider'       => 'google',
                                'identity_token' => 'c57bc496-a0d2-4426-a0e1-596ae6db40ad'
                            }
                        ],
                        'uuid' => '49f5354c-c091-4cd1-9f3d-72bbb76b6dd0'
                    },
                    'action' => 'authenticate_user'
                }}}};
}
