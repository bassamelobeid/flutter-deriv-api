use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Database::CommissionDB;
use BOM::Event::Process;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

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

    like exception { $action_handler->($args)->get; }, qr/Loginid needed/, 'correct exception when loginid is missing';
    $args->{loginid} = 'CR90000000';
    like exception { $action_handler->($args)->get; }, qr/Binary user id needed/, 'correct exception when binary_user_id is missing';
    $args->{binary_user_id} = 1;
    like exception { $action_handler->($args)->get; }, qr/CTID UserId needed/, 'correct exception when ctid_userid is missing';
    $args->{ctid_userid} = 123456;
    like exception { $action_handler->($args)->get; }, qr/Account type needed/, 'correct exception when account_type is missing';
    $args->{account_type} = 'real';

    my $result = $action_handler->($args);
    ok $result, 'Success parterid check and set upon ctrader account creation';

};

done_testing();
