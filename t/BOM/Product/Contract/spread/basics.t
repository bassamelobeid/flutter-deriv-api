#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange', {symbol => 'RANDOM'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => 'USD'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_flat',
    {
        symbol        => 'R_100',
        recorded_date => $now
    });

subtest 'entry tick' => sub {
    my $params = {
        bet_type         => 'SPREADU',
        underlying       => 'R_100',
        date_start       => $now,
        amount_per_point => 1,
        stop_loss        => 10,
        stop_profit      => 10,
        currency         => 'USD',
    };

    lives_ok {
        my $c = produce_contract({%$params, current_tick => undef});
        isa_ok $c, 'BOM::Product::Contract::Spreadu';
        is $c->entry_tick->quote, 0.01, 'entry tick is pip size value if current tick and next tick is undefiend';
        ok (($c->all_errors)[0], 'error');
        my $curr_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch,
            quote      => 100
        });
        $c = produce_contract({%$params, current_tick => $curr_tick});
        isa_ok $c, 'BOM::Product::Contract::Spreadu';
        is $c->entry_tick->quote, 100, 'current tick if next tick is undefined';
        ok (($c->all_errors)[0], 'error');

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 2,
            quote      => 104
        });
        $c = produce_contract($params);
        is $c->entry_tick->quote, 104, 'entry tick if it is defined';
        ok (!($c->all_errors)[0], 'no error');
    }
    'spreadup';
};
