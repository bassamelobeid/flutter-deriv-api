package TestHelper;

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Password;
use BOM::Platform::User;

use base 'Exporter';
use vars qw/@EXPORT_OK/;
@EXPORT_OK = qw/create_test_user/;

sub create_test_user {
    my $email     = 'abc@binary.com';
    my $password  = 'jskjd8292922';
    my $hash_pwd  = BOM::Platform::Password::hashpw($password);
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->set_default_account('USD');
    $client_cr->email($email);
    $client_cr->save;
    my $cr_1 = $client_cr->loginid;
    my $user = BOM::Platform::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->save;
    $user->add_loginid({loginid => $cr_1});
    $user->save;

    return $client_cr;
}

1;
