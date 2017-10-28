use strict;
use warnings;
use Test::More;
use JSON::MaybeXS;
use BOM::Database::Model::UserConnect;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;

my $c             = BOM::Database::Model::UserConnect->new;
my $test_user_id  = 999;
my $provider_data = sample_oneall_data();
$provider_data = $provider_data->{response}->{result}->{data};

$c->dbic->dbh->do("DELETE FROM users.binary_user_connects");
$c->dbic->dbh->do("INSERT INTO users.binary_user (id, email, password) VALUES ($test_user_id, 'dummy\@dummy.com', 'blabla')");    # for foreign key

my $res = $c->insert_connect($test_user_id, $provider_data);
ok $res->{success}, 'insert connect ok';

## someone else try same provider data is not ok
$res = $c->insert_connect(998, $provider_data);
is $res->{error}, 'CONNECTED_BY_OTHER', 'CONNECTED_BY_OTHER';

$res = $c->insert_connect($test_user_id, $provider_data);
ok $res->{success}, 'update connect ok';

my $get_user_id = $c->get_user_id_by_connect($provider_data);
is $get_user_id, $test_user_id, 'get_user_id_by_connect ok';

my @connects = $c->get_connects_by_user_id($test_user_id);
is_deeply \@connects, ['google'], 'get_connects_by_user_id ok';

my $st = $c->remove_connect($test_user_id, 'google');
ok $st, 'remove_connect ok';

@connects = $c->get_connects_by_user_id($test_user_id);
is_deeply \@connects, [], 'get_connects_by_user_id is empty after remove';

$get_user_id = $c->get_user_id_by_connect($provider_data);
is $get_user_id, undef, 'get_user_id_by_connect is undef after remove';

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
                                    'is_verified' => JSON->true]
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
