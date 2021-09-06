use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockModule;
use Test::BOM::RPC::QueueClient;
use BOM::Platform::Token::API;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;
use BOM::User;

use BOM::Platform::Token::API;
my $m = BOM::Platform::Token::API->new;

my $c = Test::BOM::RPC::QueueClient->new();

my $suspend = BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

BOM::User->create(
    email    => 'dxtrade@test.com',
    password => 'x',
)->add_client($client);

my $token = $m->create_token($client->loginid, 'test token');

my %params = (
    trading_servers => {
        language => 'EN',
        token    => $token,
        args     => {
            trading_servers => 1,
            platform        => 'dxtrade'
        }});

subtest 'suspend severs' => sub {

    $suspend->all(1);
    $suspend->demo(0);
    $suspend->real(0);

    cmp_deeply(
        $c->tcall(%params),
        bag({
                'account_type'       => 'real',
                'disabled'           => 1,
                'supported_accounts' => bag('gaming', 'financial'),
            },
            {
                'account_type'       => 'demo',
                'disabled'           => 1,
                'supported_accounts' => bag('gaming', 'financial'),
            }
        ),
        'all suspended'
    );

    $suspend->all(0);
    $suspend->demo(1);

    cmp_deeply(
        $c->tcall(%params),
        bag({
                'account_type'       => 'real',
                'disabled'           => 0,
                'supported_accounts' => bag('gaming', 'financial'),
            },
            {
                'account_type'       => 'demo',
                'disabled'           => 1,
                'supported_accounts' => bag('gaming', 'financial'),
            }
        ),
        'demo suspended'
    );

    $suspend->demo(0);
    $suspend->real(1);

    cmp_deeply(
        $c->tcall(%params),
        bag({
                'account_type'       => 'real',
                'disabled'           => 1,
                'supported_accounts' => bag('gaming', 'financial'),
            },
            {
                'account_type'       => 'demo',
                'disabled'           => 0,
                'supported_accounts' => bag('gaming', 'financial'),
            }
        ),
        'demo suspended'
    );

    $suspend->real(0);

    cmp_deeply(
        $c->tcall(%params),
        bag({
                'account_type'       => 'real',
                'disabled'           => 0,
                'supported_accounts' => bag('gaming', 'financial'),
            },
            {
                'account_type'       => 'demo',
                'disabled'           => 0,
                'supported_accounts' => bag('gaming', 'financial'),
            }
        ),
        'all available'
    );

    $suspend->real(0);
};

subtest 'account types' => sub {

    my $mock_countries = Test::MockModule->new('Brands::Countries');
    my $available      = 'gaming';
    $mock_countries->redefine(dx_company_for_country => sub { shift; my %args = @_; $args{account_type} eq $available ? 1 : 'none' });

    cmp_deeply(
        $c->tcall(%params),
        bag({
                'account_type'       => 'real',
                'disabled'           => 0,
                'supported_accounts' => ['gaming'],
            },
            {
                'account_type'       => 'demo',
                'disabled'           => 0,
                'supported_accounts' => ['gaming'],
                ,
            }
        ),
        'only gaming'
    );

    $available = 'financial';

    cmp_deeply(
        $c->tcall(%params),
        bag({
                'account_type'       => 'real',
                'disabled'           => 0,
                'supported_accounts' => ['financial'],
            },
            {
                'account_type'       => 'demo',
                'disabled'           => 0,
                'supported_accounts' => ['financial'],
            }
        ),
        'only financial'
    );

    $available = '';

    cmp_deeply($c->tcall(%params), [], 'none');
};

done_testing();
