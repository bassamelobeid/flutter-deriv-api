use strict;
use warnings;
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );
use Test::Exception tests => 2;

subtest create_promotion => sub {
    my $client = create_client();
    $client->set_promotion();
    throws_ok(sub { $client->promo_code('BOM2009s') }, qr /invalid promocode BOM2009s/, 'Dies on a Invalid Promo Code');
    ok($client->promo_code('BOM2009'),         'Set PromoCode OK');
    ok($client->promo_code_status('REJECTED'), 'Set PromoCode Status to REJECTED');  # Note that there is no DB restriction on promo_code_status text.
    ok($client->save,                          'Client saved with Promo_Code');

    my $client1 = create_client();
    $client1->account('BTC');
    throws_ok(
        sub { $client1->set_promotion() },
        qr /Promo code cannot be added to crypto currency accounts/,
        "Fails to set promotion on crypto account"
    );

    }

