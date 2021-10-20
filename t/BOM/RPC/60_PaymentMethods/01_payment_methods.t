use strict;
use warnings;

use BOM::User;
use RedisDB;

# test dependencies
use Test::MockModule;
use Test::Most;
use Test::Deep qw( cmp_deeply );

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::Database::ClientDB;

use BOM::Test::RPC::QueueClient;

use BOM::RPC::v3::PaymentMethods;

require Test::NoWarnings;

my $rpc_ct;
subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

my $email          = 'dummy' . rand(999) . '@binary.com';
my $user_client_cr = BOM::User->create(
    email          => 'cr@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    place_of_birth => 'id',
    residence      => 'br',
});
$client_cr->set_default_account('USD');

$user_client_cr->add_client($client_cr);

subtest 'PaymentMethods' => sub {
    my $params = {};
    $params->{args}->{payment_methods} = 1;
    $params->{args}->{country}         = '';

    $rpc_ct->call_ok('payment_methods', $params)->has_no_system_error->has_no_error;

    $params->{args}->{country} = 'br';

    $rpc_ct->call_ok('payment_methods', $params)->has_no_system_error->has_no_error;

    # authenticated account
    $params->{country} = '';
    $params->{token}   = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token123');
    $rpc_ct->call_ok('payment_methods', $params)->has_no_system_error->has_no_error;
};

subtest 'get_p2p_as_payment_method' => sub {

    my $expected = {
        supported_currencies => ["USD"],
        deposit_limits       => {
            "USD" => {
                "max" => 100,
                "min" => 0,
            }
        },
        deposit_time       => '',
        description        => "DP2P is Deriv's peer-to-peer deposit and withdrawal service",
        display_name       => 'DP2P',
        id                 => 'DP2P',
        payment_processor  => '',
        predefined_amounts => [5, 10, 100, 300, 500],
        signup_link        => '',
        type_display_name  => 'P2P',
        type               => '',
        withdraw_limits    => {
            "USD" => {
                "max" => 100,
                "min" => 0,
            }
        },
        withdrawal_time => '',
    };

    my $client       = $client_cr;
    my $country_code = $client->residence;

    my $p2p_payment_methods = BOM::RPC::v3::PaymentMethods::get_p2p_as_payment_method($country_code, $client);
    cmp_deeply($p2p_payment_methods, $expected, 'Call with client param only.');

    set_p2p_max_band(70);
    $expected->{deposit_limits}->{USD}->{max}  = 70;
    $expected->{withdraw_limits}->{USD}->{max} = 70;

    my $supported_countries = {
        'Indonesia' => 'id',
        'Brazil'    => 'br',
        'Egypt'     => 'eg'
    };

    for my $country (keys %$supported_countries) {
        $country_code = $supported_countries->{$country};
        $client       = undef;

        $p2p_payment_methods = BOM::RPC::v3::PaymentMethods::get_p2p_as_payment_method($country_code, $client);
        cmp_deeply($p2p_payment_methods, $expected, "Call with country param only with supported country of $country.");
    }

    my $unsupported_countries = {
        'Sweden'         => 'se',
        'Spain'          => 'es',
        'United Kingdom' => 'gb'
    };
    $expected = undef;

    for my $country (keys %$unsupported_countries) {
        $country_code = $unsupported_countries->{$country};
        $client       = undef;

        $p2p_payment_methods = BOM::RPC::v3::PaymentMethods::get_p2p_as_payment_method($country_code, $client);
        cmp_deeply($p2p_payment_methods, $expected, "Call with country param only with unsupported country of  $country.");
    }

};

sub set_p2p_max_band {
    my $max_band = shift;

    $client_cr->db->dbic->dbh->do("UPDATE p2p.p2p_country_trade_band SET  max_daily_buy = ?, max_daily_sell = ?", undef, $max_band, $max_band);
}

done_testing();

