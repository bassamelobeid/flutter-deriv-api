use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Customer;
use BOM::Database::CommissionDB;
use BOM::Event::Process;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

my $service_contexts = BOM::Test::Customer::get_service_contexts();

subtest "ctrader_account_created" => sub {
    my $myaffiliate_mock           = Test::MockModule->new('BOM::MyAffiliates');
    my $myaffiliatewebservice_mock = Test::MockModule->new('WebService::MyAffiliates');
    my $ctrader_mock               = Test::MockModule->new('BOM::TradingPlatform::CTrader');
    my $commissiondb_mock          = Test::MockModule->new('BOM::Database::CommissionDB');

    #To remove when commision DB available in Circle CI debain image
    $commissiondb_mock->mock(
        'rose_db',
        sub {
            return bless({dbic => {}}, "BOM::Database::CommissionDB");
        },
        'dbic',
        sub { return bless({run => {}}, "BOM::Database::CommissionDB") },
        'run',
        sub { return [{external_affiliate_id => 123}] });

    $myaffiliate_mock->mock(
        'get_token',
        sub {
            return 'abc123';
        });

    $myaffiliatewebservice_mock->mock(
        'get_user',
        sub {
            return {STATUS => 'accepted'};
        });

    $ctrader_mock->mock(
        'register_partnerid',
        sub {
            my ($self, $params) = @_;
            die unless $params->{account_type} eq 'real';
            die unless $params->{ctid_userid} == 123456;
            die unless $params->{partnerid} eq 'abc123';

            return 1;
        });

    # TO-DO due to missing commision DB and tight deadline, test temporary uses Mock method
    # my $dbic = BOM::Database::CommissionDB::rose_db()->dbic;
    # $dbic->run(
    #     fixup => sub {
    #         $_->do('SELECT affiliate.add_new_affiliate(?::BIGINT, ?::TEXT, ?::TEXT, ?::TEXT, ?::affiliate.affiliate_provider);',
    #             undef, 1, '153789', 'CR90000000', 'USD', 'myaffiliate');
    #     });

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{ctrader_account_created};
    my $args           = {};

    like exception { $action_handler->($args, $service_contexts)->get; }, qr/Loginid needed/, 'correct exception when loginid is missing';
    $args->{loginid} = 'CR90000000';
    like exception { $action_handler->($args, $service_contexts)->get; }, qr/Binary user id needed/,
        'correct exception when binary_user_id is missing';
    $args->{binary_user_id} = 1;
    like exception { $action_handler->($args, $service_contexts)->get; }, qr/CTID UserId needed/, 'correct exception when ctid_userid is missing';
    $args->{ctid_userid} = 123456;
    like exception { $action_handler->($args, $service_contexts)->get; }, qr/Account type needed/, 'correct exception when account_type is missing';
    $args->{account_type} = 'real';

    my $result = $action_handler->($args, $service_contexts);
    ok $result, 'Success parterid check and set upon ctrader account creation';

};

subtest 'sync_info' => sub {
    my $test_customer = BOM::Test::Customer->create(
        email_verified => 1,
        first_name     => 'AAAA',
        last_name      => 'BBBB',
        residence      => 'id',
        clients        => [{
                name        => 'CR',
                broker_code => 'CR',
            },
        ]);
    my $test_client = $test_customer->get_client_object('CR');

    $test_client->user->add_loginid("CTR100000", 'ctrader', 'real', 'USD', {login => 100000});

    my $mocked_ctrader = Test::MockModule->new('BOM::TradingPlatform::CTrader');
    $mocked_ctrader->redefine(
        call_api => sub {
            my ($self, %payload) = @_;
            return {};
        });

    $mocked_ctrader->redefine(
        get_ctid_userid => sub {
            return 100;
        });

    my $emitter_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions    = [];

    $emitter_mock->mock(
        'emit',
        sub {
            push $emissions->@*, {@_};
            return $emitter_mock->original('emit')->(@_);
        });

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{sync_user_to_CTRADER};

    subtest 'Event emit once for success case' => sub {
        $emissions = [];
        my $args = {};

        like exception { $action_handler->($args, $service_contexts)->get; }, qr/Loginid needed/, 'correct exception when loginid is missing';
        $args->{loginid} = $test_client->loginid;
        $action_handler->($args, $service_contexts);
        is(scalar @$emissions, 0, 'Event emitted once');
    };

    subtest 'Event emit again with increment retry_count for sync_error case' => sub {
        $emissions = [];

        $mocked_ctrader->redefine(
            call_api => sub {
                my ($self, %payload) = @_;
                die;
                return {};
            });

        my $args = {loginid => $test_client->loginid};
        $action_handler->($args, $service_contexts);
        is(scalar @$emissions, 1, 'Event emitted with retry');
        cmp_deeply(
            $emissions->[0],
            {
                'sync_user_to_CTRADER' => {
                    loginid     => $test_client->loginid,
                    retry_count => 1,
                }
            },
            'Event re-emitted with retry count increment'
        );
    };

    subtest 'Event dont emit again with retry_count at 5 for sync_error case' => sub {
        $emissions = [];

        $mocked_ctrader->redefine(
            call_api => sub {
                my ($self, %payload) = @_;
                die;
                return {};
            });

        my $args = {
            loginid     => $test_client->loginid,
            retry_count => 5
        };
        $action_handler->($args, $service_contexts);
        is(scalar @$emissions, 0, 'Event not emitted with retry count at 5');
    };

    $mocked_ctrader->unmock_all();
    $emitter_mock->unmock_all();
};

done_testing();
