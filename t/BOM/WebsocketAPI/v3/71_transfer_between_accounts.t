use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use Test::Exception;

use BOM::Database::Model::AccessToken;
use BOM::System::Password;
use BOM::Platform::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Transaction;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });
my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

{
    ## not malta is not allowed
    my $t = build_mojo_test();

    my $email    = 'abc@binary.com';
    my $password = 'jskjd8292922';
    my $hash_pwd = BOM::System::Password::hashpw($password);

    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_vr->email($email);
    $client_vr->save;
    $client_cr->email($email);
    $client_cr->save;
    my $vr_1 = $client_vr->loginid;
    my $cr_1 = $client_cr->loginid;

    my $user = BOM::Platform::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->save;

    $user->add_loginid({loginid => $vr_1});
    $user->add_loginid({loginid => $cr_1});
    $user->save;

    my $token = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'Test Token');
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    $t = $t->send_ok({
            json => {
                "transfer_between_accounts" => "1",
                "account_from"              => $client_cr->loginid,
                "account_to"                => $client_vr->loginid,
                "currency"                  => "EUR",
                "amount"                    => 100
            }})->message_ok;
    my $res = decode_json($t->message->[1]);

    diag Dumper(\$res);

    $t->finish_ok;
}

done_testing();
