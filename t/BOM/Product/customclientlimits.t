#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::CustomClientLimits;

my $now = time;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'GDAXI',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD EUR/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });

subtest test_everything => sub {
    my $custom_list = new_ok('BOM::Product::CustomClientLimits');
    my $bad_dude    = 'CR1001';
    my $ok_dude     = 'MLT1001';
    is_deeply($custom_list->full_list, {}, 'Sweet, empty watch list at start');
    foreach my $dude ($bad_dude, $ok_dude) {
        is($custom_list->watched($dude), undef, '... which means we are not watching ' . $dude);
    }
    ok($custom_list->remove_loginid($ok_dude), 'Removing a loginid which is not included does not hurt anything.');
    my $testing_amount = 101;
    ok(
        $custom_list->update({
                loginid       => $ok_dude,
                market        => 'forex',
                contract_kind => 'all',
                payout_limit  => $testing_amount,
                comment       => 'meanie',
                staff         => 'admin',
            }
        ),
        'Added ' . $ok_dude
    );
    is(ref $custom_list->watched($ok_dude), 'HASH', '... so he is being watched');
    is($custom_list->watched($bad_dude),    undef,  '... but other guy is not');
    my $bad_dude_info = {
        loginid       => $bad_dude,
        market        => 'random',
        contract_kind => 'iv',
        payout_limit  => $testing_amount,
        comment       => 'real meanie',
    };

    throws_ok { $custom_list->update($bad_dude_info) } qr/required parameters/, 'Fail to add ' . $bad_dude . ' because we forgot some parameters.';

    $bad_dude_info->{staff} = 'admin';
    is($custom_list->client_limit_list($bad_dude), undef, '.. leaving the per-client list undefined.');
    ok($custom_list->update($bad_dude_info), 'Added ' . $bad_dude);
    is(scalar @{$custom_list->client_limit_list($bad_dude)}, 1, '.. so he now has one limit applied..');

    my $contract_params = {
        date_start   => $now,
        date_pricing => $now,
        underlying   => 'R_100',
        bet_type     => 'CALL',
        barrier      => 20000,
        payout       => 100,
        currency     => 'USD',
        duration     => '7d',
    };
    my $r_100 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now
    });

    $contract_params->{current_tick} = $r_100;
    my $bad_contract = produce_contract($contract_params);
    is($custom_list->client_payout_limit_for_contract($bad_dude, $bad_contract),
        $testing_amount, '.. and he has his limit set for a randoms IV contract.');

    $contract_params->{bet_type} = 'DOUBLEUP';
    $contract_params->{barrier}  = 'S0P';
    my $ok_type = produce_contract($contract_params);
    is($custom_list->client_payout_limit_for_contract($bad_dude, $ok_type), undef, '.. and does not apply to random ATMs.');

    my $gdaxi = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'GDAXI',
        epoch      => $now + 1,
    });

    $contract_params->{current_tick} = $gdaxi;
    $contract_params->{bet_type}     = 'CALL';
    $contract_params->{underlying}   = 'GDAXI';
    my $ok_ul = produce_contract($contract_params);
    is($custom_list->client_payout_limit_for_contract($bad_dude, $ok_ul), undef, '.. and does not apply to index IVs.');

    is(scalar keys %{$custom_list->full_list}, 2, '... so now we have 2 entries.');

    ok($custom_list->remove_loginid($ok_dude), 'Removed first guy');
    is(scalar keys %{$custom_list->full_list}, 1,      '... so now we have 1 entry');
    is(ref $custom_list->watched($bad_dude),   'HASH', '... which is ' . $bad_dude);
    ok($custom_list->remove_loginid($bad_dude), 'Removed second guy');
    is_deeply($custom_list->full_list, {}, 'Sweet, empty watch list at end');
};
