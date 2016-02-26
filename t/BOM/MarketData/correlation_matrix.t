use strict;
use warnings;

use Test::Exception;
use Test::More tests => 2;
use Test::NoWarnings;

use Date::Utility;
use BOM::MarketData::CorrelationMatrix;
use Format::Util::Numbers qw( roundnear );
use BOM::Test::Data::Utility::UnitTestMD qw( :init );

subtest general => sub {
    plan tests => 3;

    BOM::Test::Data::Utility::UnitTestMD::create_doc('correlation_matrix', {recorded_date => Date::Utility->new('2015-05-26')});

    my $rho             = BOM::MarketData::CorrelationMatrix->new('indices');
    my $index           = 'FCHI';
    my $payout_currency = 'USD';

    my $tiy = 366 / 365;
    my $mycorr = $rho->correlation_for($index, $payout_currency, $tiy);
    is($mycorr, 0.516, "Correlation value for 1 year.");

    $tiy = 7 / 365;
    $mycorr = $rho->correlation_for($index, $payout_currency, $tiy);
    is($mycorr, 0.568782608695652, "Correlation value for 7 days.");

    $tiy = 175 / 365;
    $mycorr = $rho->correlation_for($index, $payout_currency, $tiy);
    is(roundnear(0.01, $mycorr), 0.54, "Correlation value for 175 days.");
};

