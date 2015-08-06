
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );
use BOM::Test::Mock::Exchanges qw(:init);

$ENV{MOJO_INACTIVITY_TIMEOUT} = 120;    # tolerate very slow travis environment

my $json = Mojo::JSON->new;
my $t    = Test::Mojo->new('BOM::WebsocketsAPI');

my $token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR0001",
    email           => 'cr0001@binary.com',
    expiration_time => time + 600,
)->token;
my $auth = {Authorization => "bearer $token"};
my @client = (form => {client_id => 1});

my $ul_fields = [
    sort qw( display_name exchange_is_open exchange_name intraday_interval_minutes
        is_trading_suspended pip quoted_currency_symbol spot spot_age spot_time
        symbol_type symbol )
];

subtest "Get list of symbols" => sub {
    my $mock = Test::MockModule->new('BOM::Market::Underlying');
    $mock->mock('spot',      sub { return 99999 });
    $mock->mock('spot_age',  sub { return 0.00001 });
    $mock->mock('spot_time', sub { return 99999 });

    $t->get_ok('/symbols' => $auth => @client)->status_is(200)->content_type_is('application/json')->json_has('/symbols');
    my $ul = $json->decode($t->tx->res->body);
    my @eur_usd = grep { $_->{symbol} eq 'frxEURUSD' } @{$ul->{symbols}};
    is @eur_usd, 1, "There is a single record for frxEURUSD in the list";
    is $eur_usd[0]{display_name}, 'EUR/USD', "Correct display name";
    eq_or_diff [sort keys %{$eur_usd[0]}], $ul_fields, "symbol properties contain all and only required fields";
};

subtest "Get info about particular symbol" => sub {
    $t->get_ok('/symbols/FOOBAR' => $auth => @client)->status_is(404)->content_type_is('application/json')->json_is('/fault/faultcode' => 404)
        ->json_has('/fault/faultstring');
    $t->get_ok('/symbols/frxEURUSD' => $auth => @client)->status_is(200)->content_type_is('application/json')->json_is('/display_name' => 'EUR/USD');
    $t->get_ok('/symbols/EUR-USD'   => $auth => @client)->status_is(200)->content_type_is('application/json')->json_is('/display_name' => 'EUR/USD');
};

subtest "Get price for symbol" => sub {
    $t->get_ok('/symbols/FOOBAR/price' => $auth => @client)->status_is(404)->content_type_is('application/json')->json_is('/fault/faultcode' => 404)
        ->json_has('/fault/faultstring');
    $t->get_ok('/symbols/frxEURUSD/price' => $auth => @client)->status_is(200)->content_type_is('application/json')->json_has('/price')
        ->json_has('/time')->json_is('/symbol' => 'frxEURUSD');
};

$t->get_ok('/symbols/frxEURUSD/candles' => $auth => @client)->status_is(200);
$t->get_ok('/symbols/frxEURUSD/ticks'   => $auth => @client)->status_is(200);

subtest "Authorization checks" => sub {
    note "Requests are forbiden if client_id is missing";
    $t->get_ok('/symbols'                   => $auth)->status_is(401);
    $t->get_ok('/symbols/frxEURUSD'         => $auth)->status_is(401);
    $t->get_ok('/symbols/frxEURUSD/price'   => $auth)->status_is(401);
    $t->get_ok('/symbols/frxEURUSD/ticks'   => $auth)->status_is(401);
    $t->get_ok('/symbols/frxEURUSD/candles' => $auth)->status_is(401);

    note "Requests are forbidden if Authorization header is missing";
    $t->get_ok('/symbols'                   => @client)->status_is(401);
    $t->get_ok('/symbols/frxEURUSD'         => @client)->status_is(401);
    $t->get_ok('/symbols/frxEURUSD/price'   => @client)->status_is(401);
    $t->get_ok('/symbols/frxEURUSD/ticks'   => @client)->status_is(401);
    $t->get_ok('/symbols/frxEURUSD/candles' => @client)->status_is(401);

    $token = BOM::Platform::SessionCookie->new(
        client_id       => 1,
        loginid         => "CR0001",
        email           => 'cr0001@binary.com',
        expiration_time => time + 600,
    )->token;
    $auth = {Authorization => "bearer $token"};
};

done_testing;
