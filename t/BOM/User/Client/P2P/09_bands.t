use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warn;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::Fatal;
use Test::Exception;
use Guard;

populate_exchange_rates({EUR => 2});
BOM::Test::Helper::P2P::bypass_sendbird();
my $original_admax = BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert;
BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(1000);

my $original_escrow = BOM::Config::Runtime->instance->app_config->payments->p2p->escrow;
my $escrow_client = BOM::Test::Helper::Client::create_client();
$escrow_client->account('EUR');
BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([$escrow_client->loginid]);

scope_guard {
    BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert($original_admax);
    BOM::Config::Runtime->instance->app_config->payments->p2p->escrow($original_escrow);
};

my ($client, $advertiser, $ad);

subtest 'Default band' => sub {
    $advertiser = BOM::Test::Helper::Client::create_client();
    $advertiser->account('EUR');
    $advertiser->p2p_advertiser_create(name=>'euroman');
    $advertiser->p2p_advertiser_update(is_approved=>1);
    BOM::Test::Helper::Client::top_up($advertiser, 'EUR', 1000);

    $ad = $advertiser->p2p_advert_create( amount=>500, type=>'sell', rate=>1, min_order_amount=>1, max_order_amount=>50, local_currency=>'myr',payment_method=>'bank_transfer', payment_info=>'test', contact_info=>'test');
    
    order($ad->{id}, 30);
    
    # current limit is USD 100 = EUR 50
    my $err = exception {
        order($ad->{id}, 30);
    };
    
    cmp_deeply(
        $err,
        { error_code => 'OrderMaximumTempExceeded', message_params => [ 'EUR', '20.00' ] }, 
        'cannot create order that exceeds band limit'
    );
};

subtest 'Medium band for country' => sub {
    $advertiser->db->dbic->dbh->do("INSERT INTO p2p.p2p_country_trade_band VALUES ('id','medium','USD',200,200)");
    $advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET trade_band = 'medium' WHERE id = ".$advertiser->p2p_advertiser_info->{id});
    
    # current limit is USD 200 = EUR 100, current orders are EUR 30
    lives_ok { order($ad->{id}, 30) } 'order can be created now ';

    # current orders are EUR 60
    my $err = exception {
       order($ad->{id}, 50);
    };
    
    cmp_deeply(
        $err,
        { error_code => 'OrderMaximumTempExceeded', message_params => [ 'EUR', '40.00' ] }, 
        'cannot create order that exceeds band limit'
    );
};

subtest 'High band for country & currency' => sub {
    $advertiser->db->dbic->dbh->do("INSERT into p2p.p2p_country_trade_band VALUES ('id','high','EUR',110,110)");
    $advertiser->db->dbic->dbh->do("UPDATE p2p.p2p_advertiser SET trade_band = 'high' WHERE id = ".$advertiser->p2p_advertiser_info->{id});
    
    # current limit EUR 110, current orders are EUR 60
    lives_ok { order($ad->{id}, 50) } 'order can be created now ';

    # current orders are EUR 110
    my $err = exception {
       order($ad->{id}, 10);
    };
    
    # Advert should be filtered out in db when limit currency is same as ad
    cmp_deeply(
        $err, 
        {error_code => 'AdvertNotFound'}, 
        'error is AdvertNotFound when the limit currency equals order currency'
    );
};

sub order {
    my ($advert_id, $amount) = @_;
    $client = BOM::Test::Helper::Client::create_client();
    $client->account('EUR');
    $client->p2p_order_create(advert_id=>$advert_id, amount=>$amount);
}

done_testing();
