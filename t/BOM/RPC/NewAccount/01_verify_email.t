use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Email qw(get_email_by_address_subject clear_mailbox);

use utf8;

my ( $client, $client_email );
my ( $t, $rpc_ct );
my $method = 'verify_email';

my @params = (
    $method,
    {
        language => 'RU',
        source => 1,
        country => 'ru',
    }
);

subtest 'Initialization' => sub {
    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client_email = 'some_email@binary.com';
        $client->email($client_email);
        $client->save;
    } 'Initial client';

    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );
    } 'Initial RPC server and client connection';
};

subtest 'Account opening request with email does not exist' => sub {
    clear_mailbox();

    $params[1]->{email} = 'test' . rand(999) . '@binary.com';
    $params[1]->{type}  = 'account_opening';
    $params[1]->{website_name} = 'binary.com';
    $params[1]->{link} = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
           ->has_no_system_error
           ->has_no_error
           ->result_is_deeply({ status => 1 }, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(email => $params[1]->{email}, subject => qr/Подтвердите свой электронный адрес/);
    ok keys %msg, 'Email sent successful';
};

subtest 'Account opening request with email exists' => sub {
    clear_mailbox();

    $params[1]->{email} = $client_email;
    $params[1]->{type}  = 'account_opening';
    $params[1]->{website_name} = 'binary.com';
    $params[1]->{link} = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
           ->has_no_system_error
           ->has_no_error
           ->result_is_deeply({ status => 1 }, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(email => $params[1]->{email}, subject => qr/\s/);
    ok keys %msg, 'Email sent successful';
};

done_testing();
