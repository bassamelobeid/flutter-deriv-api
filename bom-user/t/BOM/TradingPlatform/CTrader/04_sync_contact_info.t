use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use Test::Exception;
use Log::Any::Test;
use Log::Any qw($log);

subtest "cTrader Sync Contact Flow" => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'ctradersynccontact@test.com',
        first_name  => 'AAAA',
        last_name   => 'BBBB',
        residence   => 'id'
    });

    my $user = BOM::User->create(
        email    => $test_client->email,
        password => BOM::User::Password::hashpw('password'));
    $user->add_client($test_client);
    $test_client->user->add_loginid("CTR100000", 'ctrader', 'real', 'USD', {login => 100000});
    $test_client->binary_user_id($user->id);
    $test_client->save;

    my $mock_apidata = {
        ctid_getuserid => sub { {userId => 100} },
        trader_get     => sub {
            {
                login          => 100000,
                contactDetails => {}}
        },
        trader_update    => sub { {} },
        ctid_getuserid   => sub { {userId => 100} },
        ctid_changeemail => sub { {} },
    };

    my $ctrader_api_history = [];
    my $mocked_ctrader      = Test::MockModule->new('BOM::TradingPlatform::CTrader');
    $mocked_ctrader->redefine(
        call_api => sub {
            my ($self, %payload) = @_;
            push @$ctrader_api_history, {%payload};
            return $mock_apidata->{$payload{method}}->();
        });

    my $ctrader = BOM::TradingPlatform->new(
        platform    => 'ctrader',
        client      => $test_client,
        user        => $user,
        rule_engine => BOM::Rules::Engine->new(client => $test_client));
    isa_ok($ctrader, 'BOM::TradingPlatform::CTrader');

    $ctrader->_add_ctid_userid(100);

    subtest 'Contact Detail is applied to on trader_update' => sub {
        $ctrader_api_history = [];
        $ctrader->sync_account_contact_details();

        is($ctrader_api_history->[1]->{method}, 'trader_update', 'trader_update called');
        cmp_deeply(
            $ctrader_api_history->[1]->{payload},
            {
                loginid        => 100000,
                login          => 100000,
                contactDetails => {
                    email     => $test_client->email,
                    address   => $test_client->address_1,
                    state     => $test_client->state,
                    city      => $test_client->city,
                    zipCode   => $test_client->postcode,
                    countryId => 360,
                    phone     => $test_client->phone,
                },
                name     => $test_client->first_name,
                lastName => $test_client->last_name,
            },
            'contactDetails applied to trader_update'
        );
    };

    subtest 'ctid_changeemail not called if ctid_getuserid return id (correct existing email)' => sub {
        $ctrader_api_history = [];
        $ctrader->sync_account_contact_details();

        is(scalar(@$ctrader_api_history),       3,                'ctid_changeemail not called');
        is($ctrader_api_history->[0]->{method}, 'trader_get',     'trader_get called');
        is($ctrader_api_history->[1]->{method}, 'trader_update',  'trader_update called');
        is($ctrader_api_history->[2]->{method}, 'ctid_getuserid', 'ctid_getuserid called');
    };

    subtest 'ctid_changeemail is called if ctid_getuserid return none (incorrect existing email)' => sub {
        $ctrader_api_history = [];
        $mock_apidata->{ctid_getuserid} = sub { {} };
        $ctrader->sync_account_contact_details();

        is(scalar(@$ctrader_api_history),       4,                  'ctid_changeemail not called');
        is($ctrader_api_history->[0]->{method}, 'trader_get',       'trader_get called');
        is($ctrader_api_history->[1]->{method}, 'trader_update',    'trader_update called');
        is($ctrader_api_history->[2]->{method}, 'ctid_getuserid',   'ctid_getuserid called');
        is($ctrader_api_history->[3]->{method}, 'ctid_changeemail', 'ctid_changeemail called');

        cmp_deeply(
            $ctrader_api_history->[3]->{payload},
            {
                userId   => 100,
                newEmail => $test_client->email,
            },
            'ctid_changeemail called with latest email with user id'
        );

        $mock_apidata->{ctid_getuserid} = sub { {userId => 100} };
    };
};

done_testing();
