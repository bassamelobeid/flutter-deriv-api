#!/etc/rmg/bin/perl
package t::ClientRefactoring::Test2;
use strict;
use warnings;

use utf8;
use Format::Util::Strings qw( defang );
use BOM::User::Client;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User;
use BOM::User::Password;

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

use Crypt::NamedKeys;
Crypt::NamedKeys->keyfile('/etc/rmg/aes_keys.yml');

subtest 'Client getters, setters' => sub {
    my $login_id = 'CR0011';

    # create client object
    my $client;
    Test::Exception::lives_ok {
        $client = BOM::User::Client::get_instance({'loginid' => $login_id});
    }
    "Can create client object 'BOM::User::Client::get_instance({'loginid' => $login_id})'";

    is($client->broker, 'CR', 'client broker is CR');

    Test::Exception::lives_ok { $client->first_name('first-name') } "set first name: first-name";
    is($client->first_name, 'first-name', 'client first name is first-name');

    Test::Exception::lives_ok { $client->last_name('tee') } "set last name: tee";
    is($client->last_name, 'tee', 'client last name is tee');

    Test::Exception::lives_ok { $client->email('test@regentmarkets.com') } 'set email: test@regentmarkets.com';
    is($client->email, 'test@regentmarkets.com', 'client email is test@regentmarkets.com');

    my $password = '123456';
    Test::Exception::lives_ok { $client->password($password) } "set pwd 123456";
    is($client->password, $password, 'client password is 123456');

    Test::Exception::lives_ok { $client->salutation('Ms') } 'set salutation: Ms';
    is($client->salutation, 'Ms', 'client salutation is Ms');

    Test::Exception::lives_ok { $client->date_of_birth('1980-01-01') } 'set date of birth: 1980-01-01';
    is($client->date_of_birth =~ /^1980-01-01/, 1, 'client date of birth is 1980-01-01');

    Test::Exception::lives_ok { $client->residence('au') } 'set residence: au';
    is($client->residence, 'au', 'client residence is au');

    Test::Exception::lives_ok { $client->city('Cyberjaya') } 'set city: Cyberjaya';
    is($client->city, 'Cyberjaya', 'client city is Cyberjaya');

    Test::Exception::lives_ok { $client->citizen('au') } 'set citizen: au';
    is($client->citizen, 'au', 'client citizen is au');

    Test::Exception::lives_ok { $client->address_1('Jln Address 1') } 'set address_1: Jln Address 1';
    is($client->address_1, 'Jln Address 1', 'client address_1 is: Jln Address 1');

    Test::Exception::lives_ok { $client->address_2('Jln Address 2') } 'set address_2: Jln Address 2';
    is($client->address_2, 'Jln Address 2', 'client address_2 is: Jln Address 2');

    Test::Exception::lives_ok { $client->state('VIC') } 'set state: VIC';
    is($client->state, 'VIC', 'client state is: VIC');

    Test::Exception::lives_ok { $client->postcode('55010') } 'set postcode: 55010';
    is($client->postcode, '55010', 'client postcode is: 55010');

    Test::Exception::lives_ok { $client->date_joined('2009-02-20 06:08:00') } 'set date_joined: 2009-02-20 06:08:00GMT';
    is($client->date_joined, '2009-02-20 06:08:00', 'client date_joined is: 2009-02-20 06:08:00');

    my $latest_env =
        defang('16-Jul-09 08h18GMT 192.168.12.62 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.1.14) Gecko/20080404 Firefox/2.0.0.14 LANG=EN SKIN=');
    Test::Exception::lives_ok { $client->latest_environment($latest_env) } "set latest env: $latest_env";
    is($client->latest_environment, $latest_env, "client latest_environment is: $latest_env");

    # This was the original test case provided with ticket #593, believe it or
    # not. https://bitbucket.org/binarydotcom/bom/issue/593
    Test::Exception::lives_ok {
        $client->secret_question("Carlos Lima's homies live here")
    }
    "set secret question: Carlos Lima's homies live here";
    is($client->secret_question, "Carlos Lima's homies live here", "client secret question is: Carlos Lima's homies live here");

    Test::Exception::lives_ok { $client->secret_answer("São Paulo") } "set secret answer: São Paulo";
    is($client->secret_answer, "São Paulo", "client secret answer is: São Paulo");

    Test::Exception::lives_ok {
        $client->secret_answer("ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ");
    }
    "set secret answer: Unicode test";
    is($client->secret_answer, "ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ", "client secret answer is: Unicode test");

    Test::Exception::lives_ok { $client->promo_code_checked_in_myaffiliates(1) } "set promo_code_checked_in_myaffiliates: 1";
    is($client->promo_code_checked_in_myaffiliates, 1, "client promo_code has been checked in MyAffiliates.");

    Test::Exception::lives_ok { $client->promo_code("BOM2009") } "set promocode: BOM2009";
    is($client->promo_code, "BOM2009", "client promocode is: BOM2009");

    Test::Exception::lives_ok { $client->restricted_ip_address("192.168.0.1") } "set restricted_ip_address: 192.168.0.1";
    is($client->restricted_ip_address, "192.168.0.1", "client restricted_ip_address is: 192.168.0.1");

    Test::Exception::lives_ok {
        $client->save({
            'log'   => 0,
            'clerk' => 'test'
        });
    }
    "Can save all the changes back to the client";
};

my $open_account_details = {
    broker_code                   => 'CR',
    salutation                    => 'Ms',
    last_name                     => 'last-name',
    first_name                    => 'first-name',
    myaffiliates_token            => '',
    date_of_birth                 => '1979-01-01',
    citizen                       => 'au',
    residence                     => 'au',
    email                         => 'test@regentmarkets.com',
    address_line_1                => 'ADDR 1',
    address_line_2                => 'ADDR 2',
    address_city                  => 'Cyberjaya',
    address_state                 => 'State',
    address_postcode              => '55010',
    phone                         => '+60123456789',
    secret_question               => "Mother's maiden name",
    secret_answer                 => 'mei mei',
    myaffiliates_token_registered => 0,
    checked_affiliate_exposures   => 0,
    client_password               => '123456',
    binary_user_id                => BOM::Test::Data::Utility::UnitTestDatabase::get_next_binary_user_id(),
};

my $client;
subtest 'create client' => sub {
    Test::Exception::lives_ok {
        $client = $user->create_client(%$open_account_details)
    }
    "create new client success";
    my $new_loginid = $client->loginid;

    # Test save method
    $client = BOM::User::Client::get_instance({'loginid' => $new_loginid});
    $client->first_name('Amy');
    $client->last_name('mimi');
    $client->email('test@betonmarkets.com');
    Test::Exception::lives_ok { $client->save(); } "[save] call client save OK";

    BOM::User::Client::get_instance({'loginid' => $new_loginid});
    is($client->first_name,              "Amy",                   "[save] client first_name is: Amy");
    is($client->last_name,               "mimi",                  "[save] client last_name is: mimi");
    is($client->email,                   'test@betonmarkets.com', '[save] client email is: shuwnyuan@betonmarkets.com');
    is($client->aml_risk_classification, 'low',                   'by default risk classification is low for new client');
    throws_ok { $client->aml_risk_classification('dummy') }
    qr/Invalid aml_risk_classification/,
        $client->aml_risk_classification('standard');
    Test::Exception::lives_ok { $client->save(); } "[save] call client save OK";
    is($client->aml_risk_classification, 'standard', 'correct risk classification after update');

    $client->set_default_account('BTC');
    lives_ok { $client->set_payment_agent } 'No restriction on payment agent currency';
    ok $client->payment_agent, 'Client is payment agent now';
};

subtest 'Gender based on Salutation' => sub {
    my %gender_map = (
        Mr   => 'm',
        Ms   => 'f',
        Mrs  => 'f',
        Miss => 'f',
    );

    foreach my $salutation (keys %gender_map) {
        my %details = %$open_account_details;
        $details{salutation} = $salutation;
        $details{email}      = 'test+' . $salutation . '@binary.com';
        $details{first_name} = 'first-name-' . $salutation;

        $client = $user->create_client(%details);

        is($client->salutation, $salutation, 'Salutation: ' . $client->salutation);
        is($client->gender, $gender_map{$salutation}, 'gender: ' . $client->gender);
    }
};

subtest 'no salutation, default Gender: m' => sub {
    foreach my $i (0 .. 1) {
        my %details = %$open_account_details;

        if ($i == 0) {
            $details{salutation} = '';
            note 'salutation = empty string';
        } else {
            delete $details{salutation};
            note 'salutation not exists';
        }

        $details{email}      = 'test++' . $i . '@binary.com';
        $details{first_name} = 'first-name-' . $i;
        $client              = $user->create_client(%details);

        is($client->salutation, '',  'Salutation: ' . $client->salutation);
        is($client->gender,     'm', 'default gender: m');
    }
};

subtest 'no salutation, set Gender explicitly' => sub {
    my %details = %$open_account_details;

    $details{salutation} = '';
    $details{gender}     = 'f';
    $details{email}      = 'test++ff@binary.com';
    $details{first_name} = 'first-name-ff';
    $client              = $user->create_client(%details);

    is($client->salutation, '',  'Salutation: ' . $client->salutation);
    is($client->gender,     'f', 'gender: ' . $client->gender);
};

