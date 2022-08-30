use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;

use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase          qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase          qw(:init);
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Platform::Token::API;
use BOM::Database::ClientDB;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;

use utf8;

my ($client, $client_token, $oauth_token, $app, $app1);
my $rpc_ct;
my $method = 'app_markup_statistics';

my @params = (
    $method,
    {
        args => {
            date_from => "2022-01-01 00:00:00",
            date_to   => "2022-08-31 23:59:59",
        },
    });

subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server';

    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client->payment_free_gift(
            currency => 'USD',
            amount   => 500,
            remark   => 'free gift',
        );

        my $m = BOM::Platform::Token::API->new;
        $client_token = $m->create_token($client->loginid, 'test token');

        ($oauth_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

        $app = $rpc_ct->call_ok(
            'app_register',
            {
                token => $oauth_token,
                args  => {
                    name             => 'App',
                    scopes           => ['read', 'trade'],
                    redirect_uri     => 'https://www.example.com/',
                    verification_uri => 'https://www.example.com/verify',
                    homepage         => 'https://www.homepage.com/',
                },
            })->has_no_system_error->has_no_error->result;
        $app1 = $rpc_ct->call_ok(
            'app_register',
            {
                token => $oauth_token,
                args  => {
                    name             => 'App 1',
                    scopes           => ['read', 'trade'],
                    redirect_uri     => 'https://www.example.com/',
                    verification_uri => 'https://www.example.com/verify',
                    homepage         => 'https://www.homepage.com/',
                },
            })->has_no_system_error->has_no_error->result;

        my $collector_db = BOM::Database::ClientDB->new({
                broker_code => 'FOG',
                operation   => 'collector'
            })->db->dbic;
        my $query = q{
            INSERT INTO data_collection.app_markup_payable VALUES ('cr', 123, ?, '2022-07-12 07:40:19 ', 40.0, 'USD', 'USD', ?, 40.0, 40.0, ? );
            INSERT INTO data_collection.app_markup_payable VALUES ('cr', 124, ?, '2020-07-12 07:40:19 ', 40.0, 'USD', 'USD', ?, 40.0, 40.0, ? );
            INSERT INTO data_collection.app_markup_payable VALUES ('cr', 125, ?, '2022-07-12 07:40:19 ', 20.0, 'USD', 'USD', ?, 20.0, 20.0, ? );
            INSERT INTO data_collection.app_markup_payable VALUES ('cr', 126, ?, '2020-07-12 07:40:19 ', 20.0, 'USD', 'USD', ?, 20.0, 20.0, ? );
            INSERT INTO data_collection.app_markup_payable VALUES ('cr', 127, ?, '2022-07-12 07:40:19 ', 40.0, 'USD', 'USD', ?, 40.0, 40.0, ? );
            INSERT INTO data_collection.app_markup_payable VALUES ('cr', 128, ?, '2020-07-12 07:40:19 ', 40.0, 'USD', 'USD', ?, 40.0, 40.0, ? );
            INSERT INTO data_collection.app_markup_payable VALUES ('cr', 129, ?, '2022-07-12 07:40:19 ', 20.0, 'USD', 'USD', ?, 20.0, 20.0, ? );
            INSERT INTO data_collection.app_markup_payable VALUES ('cr', 130, ?, '2020-07-12 07:40:19 ', 20.0, 'USD', 'USD', ?, 20.0, 20.0, ? );
            INSERT INTO data_collection.app_markup_payable VALUES ('cr', 131, ?, '2022-07-12 07:40:19 ', 90.0, 'USD', 'USD', ?, 90.0, 90.0, ? );
        };
        my $loginid  = $client->loginid;
        my $loginid1 = $client->loginid . '1';
        my @binds;
        push @binds, $app->{app_id},  $loginid,  $loginid;
        push @binds, $app->{app_id},  $loginid,  $loginid;
        push @binds, $app1->{app_id}, $loginid,  $loginid;
        push @binds, $app1->{app_id}, $loginid,  $loginid;
        push @binds, $app->{app_id},  $loginid,  $loginid1;
        push @binds, $app->{app_id},  $loginid,  $loginid1;
        push @binds, $app1->{app_id}, $loginid,  $loginid1;
        push @binds, $app1->{app_id}, $loginid,  $loginid1;
        push @binds, 999,             $loginid1, $loginid;

        $collector_db->run(
            ping => sub {
                $_->do($query, undef, @binds);
            });
    }
    'Initial clients';
};

subtest 'Auth client' => sub {
    $params[1]->{token} = $oauth_token;
    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('It should be success using oauth token');
};

subtest 'Return app markup statistics' => sub {
    my $result             = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    my $expected_stat_data = [{
            'app_markup_usd'     => '80.0',
            'app_id'             => $app->{app_id},
            'dev_currcode'       => 'USD',
            'app_markup_value'   => '80.0',
            'transactions_count' => 2,
        },
        {
            'app_markup_usd'     => '40.0',
            'app_id'             => $app1->{app_id},
            'dev_currcode'       => 'USD',
            'app_markup_value'   => '40.0',
            'transactions_count' => 2,
        }];
    is_deeply($result->{breakdown}, $expected_stat_data, 'Should return statistic data');
    is($result->{total_app_markup_usd},     120, 'Should return statistic data');
    is($result->{total_transactions_count}, 4,   'Should return statistic data');

    @params = (
        $method,
        {
            token => $oauth_token,
            args  => {
                date_from => "2020-01-01 00:00:00",
                date_to   => "2022-08-31 23:59:59",
            },
        });

    $result             = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    $expected_stat_data = [{
            'app_markup_usd'     => '160.0',
            'app_id'             => $app->{app_id},
            'dev_currcode'       => 'USD',
            'app_markup_value'   => '160.0',
            'transactions_count' => 4,
        },
        {
            'app_markup_usd'     => '80.0',
            'app_id'             => $app1->{app_id},
            'dev_currcode'       => 'USD',
            'app_markup_value'   => '80.0',
            'transactions_count' => 4,
        }];
    is_deeply($result->{breakdown}, $expected_stat_data, 'Should return statistic data');
    is($result->{total_app_markup_usd},     240, 'Should return statistic data');
    is($result->{total_transactions_count}, 8,   'Should return statistic data');
};

done_testing();
