use strict;
use warnings;

use 5.010;
use Test::Most;

use List::Util qw( max );
use Test::MockObject::Extends;
use Test::FailWarnings;
use Test::Warn;

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;
use BOM::Market::Underlying;
use BOM::Test::Data::Utility::UnitTestMarketData;

my @expiry_dates = ( 
    Date::Utility->new('2016-05-05'),
    Date::Utility->new('2016-05-06'),
    Date::Utility->new('2016-05-09') );

my @expectations = (
    0.154901586024009, 0.154728689545355, 0.154545663875847, 0.154351539625487, 0.154145215206817,
    0.153925433050604, 0.153110576237393, 0.152889797370248, 0.152655062326315, 0.152404968744331,
    0.152137917003775, 0.151852073986206, 0.163835204764086, 0.163965745461123, 0.164104661765745,
    0.164252786639814, 0.164411067307955, 0.164580585550523, 0.150955402439733, 0.150955402439733,
    0.150955402439733, 0.150955402439733, 0.150955402439733, 0.150955402439733, 0.150955402439733,
    0.150955402439733, 0.150955402439733, 0.150955402439733, 0.150955402439733, 0.150955402439733,
    0.151022745508026, 0.150738211664355, 0.150434577587039, 0.150109851178082, 0.149761753006611,
    0.149387662497983, 0.151071916844003, 0.150786813169592, 0.150482570649127, 0.150157193113217,
    0.149808396464875, 0.149433554755611, 0.151123180437856, 0.150837890670439, 0.150533449927523,
    0.150207860813782, 0.149858837835307, 0.149483753444811, 0.151164686167803, 0.150879245448185,
    0.150574643912745, 0.15024888317145, 0.149899676596928, 0.149557209898497, 0.154901586024009,
    0.154728689545355, 0.154545663875847, 0.154351539625487, 0.154145215206817, 0.153925433050604,
    0.163740633949077, 0.16387103022208, 0.164009792717368, 0.164157753451216, 0.164315858571223,
    0.164485188625607, 0.150881097907292, 0.150881097907292, 0.150881097907292, 0.150881097907292,
    0.150881097907292, 0.150881097907292, 0.150881097907292, 0.150881097907292, 0.150881097907292,
    0.150881097907292, 0.150881097907292, 0.150881097907292, 0.150955402439733, 0.150671111704478,
    0.150367736580291, 0.150043286570534, 0.149695484069028, 0.149321710589506, 0.151012179768557,
    0.150727292488066, 0.150423280465277, 0.150098148956221, 0.149749615488127, 0.149375055971438,
    0.151071916844003, 0.150786813169592, 0.150482570649127, 0.150157193113217, 0.149808396464875,
    0.149433554755611, 0.151123180437856, 0.150837890670439, 0.150533449927523, 0.150207860813782,
    0.149858837835307, 0.149483753444811, 0.16417988703136, 0.16431095657027, 0.164450436082298,
    0.164599161991595, 0.164758085466338, 0.164967968329857, 0.145014545886038, 0.145014545886038,
    0.145014545886038, 0.145014545886038, 0.145014545886038, 0.145014545886038, 0.153119580684823,
    0.152899073237004, 0.152664627224121, 0.152414842101941, 0.152148120329536, 0.151862631180208,
    0.150789783729691, 0.150505698615201, 0.15020254104087, 0.149878321546811, 0.149530763681315,
    0.149157250246008, 0.150870551151544, 0.150586175264977, 0.150282707966729, 0.149958157881448,
    0.149610246374802, 0.149236353750365, 0.150944845735426, 0.150660201849062, 0.150356449083778,
    0.150031594298852, 0.149683356848365, 0.149309114733603, 0.164071120293398, 0.164202022484964,
    0.164341323775539, 0.16448985949378, 0.164648579560104, 0.164818568838881, 0.15113376111824,
    0.15113376111824, 0.15113376111824, 0.15113376111824, 0.15113376111824, 0.15113376111824,
    0.15113376111824, 0.15113376111824, 0.15113376111824, 0.15113376111824, 0.15113376111824,
    0.15113376111824, 0.151175272451729, 0.150890185818687, 0.150585962920926, 0.15026060801869,
    0.149911837531408, 0.149569846059421,

);
my $counter = 0;

for my $expiry (@expiry_dates) {
    my $start_date = $expiry->minus_time_interval('8d');
    my $end_of_day = $expiry->plus_time_interval('23h59m59s');
    my @dates;

    while ($start_date->is_before($end_of_day)) {
        push @dates, $start_date;
        $start_date = $start_date->plus_time_interval('4h');
    }

    foreach my $date (@dates) {
        price_contract($date, $end_of_day, $expectations[$counter]);
        $counter++;
    }
}

sub price_contract {
    my ($date_start, $date_expiry, $expected_pricing_vol) = @_;

    my $surface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            recorded_date => $date_start,
            symbol => 'frxUSDJPY',
        });

    Quant::Framework::Utils::Test::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $date_start,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        }) for (qw/JPY USD JPY-USD/);

    my $c = produce_contract({
            bet_type => 'CALL',
            underlying => 'frxUSDJPY',
            barrier => 'S0P',
            currency => 'USD',
            payout => 100,
            date_expiry => $date_expiry,
            date_start =>  $date_start,
            date_pricing => $date_start,
        });

    is $c->pricing_vol, $expected_pricing_vol, "correct pricing_vol [$counter]";
}

done_testing;
