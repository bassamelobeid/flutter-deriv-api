#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Exception;
use Test::NoWarnings;

use BOM::Product::Pricing::Parameter qw(get_parameter);

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use Date::Utility;
use BOM::Market::Underlying;
use BOM::Market::AggTicks;
use BOM::Product::Pricing::Parameter qw(get_parameter);

my $now = Date::Utility->new->minus_time_interval('32m');
my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange', {symbol => 'FOREX'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => $_}) for qw(USD JPY JPY-USD EUR);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('volsurface_delta', {symbol => $_, recorded_date => $now}) for qw(frxEURJPY frxUSDJPY);
my $at = BOM::Market::AggTicks->new;
$at->flush;

subtest 'vol_proxy and trend proxy' => sub {
    # 19 ticks
    for (-20 .. -2) {
        BOM::Market::AggTicks->new->add({symbol => $underlying->symbol, epoch => $now->epoch + $_, quote => rand(1)});
    }
    my $vol_proxy_reference = get_parameter('vol_proxy', {underlying => $underlying, date_pricing => $now});
    is $vol_proxy_reference->{value}, 0.2, 'default 20% volatility if not enough ticks';
    like $vol_proxy_reference->{error}, qr/not have enough ticks/, 'error if not enough ticks';

    my $trend_proxy_reference = get_parameter('trend_proxy', {underlying => $underlying, date_pricing => $now});
    like $vol_proxy_reference->{error}, qr/not have enough ticks/, 'error if not enough ticks';
    is $trend_proxy_reference->{value}, 0, 'zero trend';

    BOM::Market::AggTicks->new->add({symbol => $underlying->symbol, epoch => $now->epoch - 1, quote => 100});
    $vol_proxy_reference = get_parameter('vol_proxy', {underlying => $underlying, date_pricing => $now});
    ok !$vol_proxy_reference->{error}, 'no error';
    isnt $vol_proxy_reference->{value}, 0.2, 'vol proxy isn\'t 0.2';
    $trend_proxy_reference = get_parameter('trend_proxy', {underlying => $underlying, date_pricing => $now});
    isnt $trend_proxy_reference->{value}, 0, 'trend proxy isn\'t 0';
};

subtest 'economic_events' => sub {
    my $underlying = BOM::Market::Underlying->new('frxEURJPY');
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('economic_events', {symbol => 'USD', release_date => $now, recorded_date => $now});
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('economic_events', {symbol => 'EUR', release_date => $now, recorded_date => $now});
    my @eco = get_parameter('economic_events', {underlying => $underlying, start => $now, end => $now->plus_time_interval('1h')});
    is scalar @eco, 2, 'directly affected currency and influential currency are included';
};
