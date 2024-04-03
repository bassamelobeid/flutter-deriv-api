use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;

use BOM::Test;
use BOM::CTrader::Script::CtraderSetPartnerId;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Date::Utility;
use Data::Dumper;

use BOM::Config;
use BOM::Config::Redis;
use BOM::Database::CommissionDB;
use BOM::Database::UserDB;
use BOM::User::Client;
use BOM::User;
use Future::AsyncAwait;

subtest "Test module functions" => async sub {

    subtest 'Test initialize module' => async sub {

        my $ctrader_set_partner_id = BOM::CTrader::Script::CtraderSetPartnerId->new();

        isa_ok $ctrader_set_partner_id, 'BOM::CTrader::Script::CtraderSetPartnerId';

    };

    subtest 'Test _get_ib_details_from_db function' => async sub {

        my $expected = [['111', 'my_aff_111'], ['222', 'my_aff_222'], ['333', 'my_aff_333']];

        my @args;
        my $mock = Test::MockModule->new('BOM::CTrader::Script::CtraderSetPartnerId');
        $mock->mock(
            '_get_ib_details_from_db',
            async sub {
                (@args) = @_;
                return $expected;
            });

        my $ctrader_set_partner_id = BOM::CTrader::Script::CtraderSetPartnerId->new();

        my $result = $ctrader_set_partner_id->_get_ib_details_from_db('2023-07-22', 0)->get;

        is $args[1], '2023-07-22', 'Expected date';

        is_deeply($result, $expected, 'Arrays match');

        $mock->unmock_all;

    };

    subtest 'Test _get_ctid_of_ib function' => async sub {

        my $expected = ['303'];

        my @args;
        my $mock = Test::MockModule->new('BOM::CTrader::Script::CtraderSetPartnerId');
        $mock->mock(
            '_get_ctid_of_ib',
            async sub {
                (@args) = @_;
                return $expected;
            });

        my $ctrader_set_partner_id = BOM::CTrader::Script::CtraderSetPartnerId->new();

        my $result = $ctrader_set_partner_id->_get_ctid_of_ib(303)->get;

        is $args[1], 303, 'Expected id';

        is_deeply($result, $expected, 'Arrays match');

        $mock->unmock_all;

    };

};

subtest "Test cTrader API" => async sub {

    subtest 'Get Partner ID for existing CTID' => async sub {

        my $params = {
            method  => "ctid_readreferral",
            path    => "cid",
            payload => {userId => 808220}};

        my @args;
        my $mock = Test::MockModule->new('BOM::CTrader::Script::CtraderSetPartnerId');
        $mock->mock(
            '_call_api',
            async sub {
                (@args) = @_;
                return [{
                        'partnerId' => 'asd123',
                        'userId'    => 808220
                    }];
            });

        my $ctrader_set_partner_id = BOM::CTrader::Script::CtraderSetPartnerId->new();

        my $result = $ctrader_set_partner_id->_call_api($params)->get;

        is_deeply($args[1], $params, 'Params match');

        is_deeply(
            $result,
            [{
                    'partnerId' => 'asd123',
                    'userId'    => 808220
                }
            ],
            'Expected result'
        );

        $mock->unmock_all;

    };

    subtest 'Get Partner ID for non existent CTID' => async sub {

        my $params = {
            method  => "ctid_readreferral",
            path    => "cid",
            payload => {userId => 999}};

        my @args;
        my $mock = Test::MockModule->new('BOM::CTrader::Script::CtraderSetPartnerId');
        $mock->mock(
            '_call_api',
            async sub {
                (@args) = @_;
                return {
                    'error' => {
                        'errorCode'   => 'ENTITY_NOT_FOUND',
                        'description' => 'Can\'t find user with id=999'
                    }};
            });

        my $ctrader_set_partner_id = BOM::CTrader::Script::CtraderSetPartnerId->new();

        my $result = $ctrader_set_partner_id->_call_api($params)->get;

        is_deeply($args[1], $params, 'Params match');

        is_deeply(
            $result,
            {
                'error' => {
                    'errorCode'   => 'ENTITY_NOT_FOUND',
                    'description' => 'Can\'t find user with id=999'
                }
            },
            'Expected result'
        );

        $mock->unmock_all;

    };

    subtest 'Set Partner ID for existing CTID' => async sub {

        my $params = {
            method  => "ctid_referral",
            path    => "cid",
            payload => {
                userId    => 999,
                partnerId => 'asd123',
            }};

        my @args;
        my $mock = Test::MockModule->new('BOM::CTrader::Script::CtraderSetPartnerId');
        $mock->mock(
            '_call_api',
            async sub {
                (@args) = @_;
                return {};
            });

        my $ctrader_set_partner_id = BOM::CTrader::Script::CtraderSetPartnerId->new();

        my $result = $ctrader_set_partner_id->_call_api($params)->get;

        is_deeply($args[1], $params, 'Params match');

        is_deeply($result, {}, 'Expected result');

        $mock->unmock_all;

    };

    subtest 'Set Partner ID for non existent CTID' => async sub {

        my $params = {
            method  => "ctid_referral",
            path    => "cid",
            payload => {
                userId    => 999,
                partnerId => 'asd123',
            }};

        my @args;
        my $mock = Test::MockModule->new('BOM::CTrader::Script::CtraderSetPartnerId');
        $mock->mock(
            '_call_api',
            async sub {
                (@args) = @_;
                return {
                    'error' => {
                        'errorCode'   => 'ENTITY_NOT_FOUND',
                        'description' => 'Can\'t find user with id=999'
                    }};
            });

        my $ctrader_set_partner_id = BOM::CTrader::Script::CtraderSetPartnerId->new();

        my $result = $ctrader_set_partner_id->_call_api($params)->get;

        is_deeply($args[1], $params, 'Params match');

        is_deeply(
            $result,
            {
                'error' => {
                    'errorCode'   => 'ENTITY_NOT_FOUND',
                    'description' => 'Can\'t find user with id=999'
                }
            },
            'Expected result'
        );

        $mock->unmock_all;

    };

};

done_testing();
