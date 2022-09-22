use Test::Most;
#use Test::MockTime::HiRes qw(set_absolute_time);
use BOM::Pricing::v3::Contract;
use Test::MockModule;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
#set_absolute_time('2022-10-21T00:00:00Z');
note "set time to: " . Date::Utility->new->date ." - " . Date::Utility->new->epoch;
initialize_realtime_ticks_db();

local $SIG{__WARN__} = sub {
    # capture the warn for test
    my $msg = shift;
     #  note $msg;

};

my $params = {
    landing_company => 'svg',
    short_code      => "TEST",
    currency        => 'USD',
            contract_id     => 1,
        is_sold         => 0,
        country_code    => 'cr',
};

#my $mock_contract = Test::MockModule->new('BOM::Pricing::v3::Contract');

#$mock_contract->shortcode_to_parameters


my $result = BOM::Pricing::v3::Contract::get_bid($params);
is  $result->{error}->{code} ,'GetProposalFailure' ,$result->{error}->{message_to_client} ;
$params->{short_code}="TICKHIGH_R_50_100_1619506193_10t_1";
  #  my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
 # $mock_contract->mock('is_legacy', sub { return 1 });

 $result = BOM::Pricing::v3::Contract::get_bid($params);
 is  $result->{error}->{code} ,'GetProposalFailure' , $result->{error}->{message_to_client} ;


$params->{short_code}="DIGITMATCH_R_10_18.18_0_5T_7_0";
$result = BOM::Pricing::v3::Contract::get_bid($params);

is $result->{bid_price} , '1.64', 'check bid_price';

$params->{short_code}="RUNHIGH_R_100_100.00_1619507455_3T_S0P_0";
 $result = BOM::Pricing::v3::Contract::send_bid($params);
 ok  $result->{rpc_time} ,'send_bid ok' ;



done_testing;
