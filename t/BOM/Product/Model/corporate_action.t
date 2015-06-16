#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 6);

use Test::Exception;
use Test::NoWarnings;

use Date::Utility;

use BOM::MarketData::CorporateAction;
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);

subtest 'general' => sub {
    plan tests => 5;
    lives_ok { BOM::MarketData::CorporateAction->new(symbol => 'UKAAL') } 'creates corporate action object with symbol';
    throws_ok { BOM::MarketData::CorporateAction->new } qr/Attribute \(symbol\) is required/, 'throws exception if symbol is not provided';
    lives_ok {
        my $corp = BOM::MarketData::CorporateAction->new(symbol => 'UKHBSA');
        isa_ok($corp->actions, 'HASH');
        ok !keys %{$corp->actions}, 'empty hash';
    }
    'does not die if no actions are present on couch';
};

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('corporate_action');

subtest 'save new corporate actions' => sub {
    plan tests => 7;
    my $now = Date::Utility->new;
    lives_ok {
        my $corp = BOM::MarketData::CorporateAction->new(symbol => 'UKAAL');
        my $actions = $corp->actions;
        is keys %$actions, 1, 'has only one action';
        my $new_actions = {
            1122334 => {
                effective_date => $now->datetime_iso8601,
                modifier       => 'multiplication',
                value          => 1.456,
                description    => 'Test data 2',
                flag           => 'N'
            }};
        my $new_corp = BOM::MarketData::CorporateAction->new(
            symbol        => 'UKAAL',
            actions       => $new_actions,
            recorded_date => $now
        );
        ok $new_corp->save, 'saves new action';
        my $after_save_corp = BOM::MarketData::CorporateAction->new(symbol => 'UKAAL');
        my $new_actions_from_couch = $after_save_corp->actions;
        is keys %$new_actions_from_couch, 2, 'has two actions';
    }
    'save new action';

    lives_ok {
        my $new_actions = {
            1122334 => {
                effective_date => $now->datetime_iso8601,
                modifier       => 'multiplication',
                value          => 1.456,
                description    => 'Duplicate action',
                flag           => 'N'
            }};
        my $no_dup_corp = BOM::MarketData::CorporateAction->new(
            symbol        => 'UKAAL',
            actions       => $new_actions,
            recorded_date => $now,
        );
        ok $no_dup_corp->save, 'try to save duplicate action';
        my $after_save = BOM::MarketData::CorporateAction->new(symbol => 'UKAAL');
        my $action = $after_save->actions;
        cmp_ok($action->{1122334}->{description}, "ne", 'Duplicate action', 'did not save duplicate action');
    }
    'No duplicate actions save';
};

subtest 'update existing corporate actions' => sub {
    plan tests => 5;
    lives_ok {
        my $now         = Date::Utility->new;
        my $action_id   = 1122334;
        my $new_actions = {
            $action_id => {
                effective_date => $now->datetime_iso8601,
                modifier       => 'multiplication',
                value          => 1.987,
                description    => 'Update to existing actions',
                flag           => 'U'
            }};
        my $new_corp = BOM::MarketData::CorporateAction->new(
            symbol        => 'UKAAL',
            actions       => $new_actions,
            recorded_date => $now
        );
        ok $new_corp->save, 'saves new action';
        my $after_save_corp = BOM::MarketData::CorporateAction->new(symbol => 'UKAAL');
        my $new_actions_from_couch = $after_save_corp->actions;
        is keys %$new_actions_from_couch, 2, 'has two actions';
        my $updated_action = $new_actions_from_couch->{$action_id};
        is $updated_action->{description}, 'Update to existing actions', 'description is updated';
        is $updated_action->{value}, 1.987, 'value is also updated';
    }
    'update existing action';
};

subtest 'cancel existing corporate actions' => sub {
    plan tests => 4;
    lives_ok {
        my $now         = Date::Utility->new;
        my $action_id   = 1122334;
        my $new_actions = {
            $action_id => {
                effective_date => $now->datetime_iso8601,
                modifier       => 'multiplication',
                value          => 1.987,
                description    => 'Update to existing actions',
                flag           => 'D'
            }};
        my $new_corp = BOM::MarketData::CorporateAction->new(
            symbol        => 'UKAAL',
            actions       => $new_actions,
            recorded_date => $now
        );
        ok $new_corp->save, 'saves new action';
        my $after_save_corp = BOM::MarketData::CorporateAction->new(symbol => 'UKAAL');
        my $new_actions_from_couch = $after_save_corp->actions;
        is keys %$new_actions_from_couch, 1, 'has one actions';
        ok !$new_actions_from_couch->{$action_id}, 'action deleted from couch';
    }
    'cancel existing action';
};

subtest 'save critical actions' => sub {
    plan tests => 5;
    lives_ok {
        my $now         = Date::Utility->new;
        my $action_id   = 11223346;
        my $new_actions = {
            $action_id => {
                effective_date  => $now->datetime_iso8601,
                suspend_trading => 1,
                disabled_date   => $now->datetime_iso8601,
                description     => 'Save critical action',
                flag            => 'N'
            }};
        my $new_corp = BOM::MarketData::CorporateAction->new(
            symbol        => 'UKAAL',
            actions       => $new_actions,
            recorded_date => $now
        );
        ok $new_corp->save, 'saves critical action';
        my $after_save_corp = BOM::MarketData::CorporateAction->new(symbol => 'UKAAL');
        my $new_actions_from_couch = $after_save_corp->actions;
        is keys %$new_actions_from_couch, 2, 'has two actions';
        ok $new_actions_from_couch->{$action_id}, 'critical action saved on couch';
        ok $new_actions_from_couch->{$action_id}->{suspend_trading}, 'suspend_trading';
    }
    'save critical action';
};
