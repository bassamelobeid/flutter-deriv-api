#!/usr/bin/perl
package t::ClientRefactoring::Test2;

# PURPOSE: Perform unit tests on the refactored getter / setter of Client object

use strict;
use warnings;

use utf8;

use BOM::System::Password;
use Format::Util::Strings qw( defang );
use BOM::Platform::Client;
use BOM::Platform::Client::Utility;
use BOM::Utility::Config;

use FindBin;
use lib "$FindBin::Bin/../../..";    #cgi
use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

subtest 'Client getters, setters and create' => sub {
    my $login_id = 'CR0011';

    # create client object
    my $client;
    Test::Exception::lives_ok { $client = BOM::Platform::Client::get_instance({'loginid' => $login_id}); }
    "Can create client object 'BOM::Platform::Client::get_instance({'loginid' => $login_id})'";

    is($client->broker, 'CR', 'client broker is CR');

    Test::Exception::lives_ok { $client->first_name('shuwnyuan') } "set first name: shuwnyuan";
    is($client->first_name, 'shuwnyuan', 'client first name is shuwnyuan');

    Test::Exception::lives_ok { $client->last_name('tee') } "set last name: tee";
    is($client->last_name, 'tee', 'client last name is tee');

    Test::Exception::lives_ok { $client->email('shuwnyuan@regentmarkets.com') } 'set email: shuwnyuan@regentmarkets.com';
    is($client->email, 'shuwnyuan@regentmarkets.com', 'client email is shuwnyuan@regentmarkets.com');

    my $password = BOM::System::Password::hashpw('123456');
    Test::Exception::lives_ok { $client->password($password) } "set pwd 123456";
    is($client->password, $password, 'client password is 123456');

    Test::Exception::lives_ok { $client->salutation('Ms') } 'set salutation: Ms';
    is($client->salutation, 'Ms', 'client salutation is Ms');

    Test::Exception::lives_ok { $client->date_of_birth('1980-01-01') } 'set date of birth: 1980-01-01';
    is($client->date_of_birth =~ /^1980-01-01/, 1, 'client date of birth is 1980-01-01');

    Test::Exception::lives_ok { $client->residence('au') } 'set residence: au';
    is($client->residence, 'au', 'client residence is au');

    Test::Exception::lives_ok { $client->city('Segamat') } 'set city: Segamat';
    is($client->city, 'Segamat', 'client city is Segamat');

    Test::Exception::lives_ok { $client->citizen('au') } 'set citizen: au';
    is($client->citizen, 'au', 'client citizen is au');

    Test::Exception::lives_ok { $client->address_1('53, Jln Address 1') } 'set address_1: 53, Jln Address 1';
    is($client->address_1, '53, Jln Address 1', 'client address_1 is: 53, Jln Address 1');

    Test::Exception::lives_ok { $client->address_2('Jln Address 2') } 'set address_2: Jln Address 2';
    is($client->address_2, 'Jln Address 2', 'client address_2 is: Jln Address 2');

    Test::Exception::lives_ok { $client->state('VIC') } 'set state: VIC';
    is($client->state, 'VIC', 'client state is: VIC');

    Test::Exception::lives_ok { $client->postcode('85010') } 'set postcode: 85010';
    is($client->postcode, '85010', 'client postcode is: 85010');

    Test::Exception::lives_ok { $client->date_joined('2009-02-20 06:08:00') } 'set date_joined: 2009-02-20 06:08:00GMT';
    is($client->date_joined, '2009-02-20 06:08:00', 'client date_joined is: 2009-02-20 06:08:00');

    my $latest_env =
        defang('16-Jul-09 08h18GMT 192.168.12.62 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.1.14) Gecko/20080404 Firefox/2.0.0.14 LANG=EN SKIN=');
    Test::Exception::lives_ok { $client->latest_environment($latest_env) } "set latest env: $latest_env";
    is($client->latest_environment, $latest_env, "client latest_environment is: $latest_env");

    # This was the original test case provided with ticket #593, believe it or
    # not. https://bitbucket.org/binarydotcom/bom/issue/593
    Test::Exception::lives_ok { $client->secret_question("Carlos Lima's homies live here") } "set secret question: Carlos Lima's homies live here";
    is($client->secret_question, "Carlos Lima's homies live here", "client secret question is: Carlos Lima's homies live here");

    Test::Exception::lives_ok { $client->secret_answer(BOM::Platform::Client::Utility::encrypt_secret_answer("São Paulo")) }
    "set secret answer: São Paulo";
    is(BOM::Platform::Client::Utility::decrypt_secret_answer($client->secret_answer), "São Paulo", "client secret answer is: São Paulo");

    Test::Exception::lives_ok {
        $client->secret_answer(BOM::Platform::Client::Utility::encrypt_secret_answer("ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ"))
    }
    "set secret answer: Unicode test";
    is(
        BOM::Platform::Client::Utility::decrypt_secret_answer($client->secret_answer),
        "ѦѧѨѩѪԱԲԳԴԵԶԷႤႥႦႧᚕᚖᚗᚘᚙᚚ",
        "client secret answer is: Unicode test"
    );

    Test::Exception::lives_ok { $client->promo_code_checked_in_myaffiliates(1) } "set promo_code_checked_in_myaffiliates: 1";
    is($client->promo_code_checked_in_myaffiliates, 1, "client promo_code has been checked in MyAffiliates.");

    Test::Exception::lives_ok { $client->promo_code("BOM2009") } "set promocode: BOM2009";
    is($client->promo_code, "BOM2009", "client promocode is: BOM2009");

    Test::Exception::lives_ok { $client->restricted_ip_address("192.168.0.1") } "set restricted_ip_address: 192.168.0.1";
    is($client->restricted_ip_address, "192.168.0.1", "client restricted_ip_address is: 192.168.0.1");

    Test::Exception::lives_ok { $client->save({'log' => 0, 'clerk' => 'shuwnyuan'}); } "Can save all the changes back to the client";

    my $open_account_details = {
        broker_code                   => 'CR',
        salutation                    => 'Ms',
        last_name                     => 'shuwnyuan',
        first_name                    => 'tee',
        myaffiliates_token            => '',
        date_of_birth                 => '1979-01-01',
        citizen                       => 'au',
        residence                     => 'au',
        email                         => 'shuwnyuan@regentmarkets.com',
        address_line_1                => 'ADDR 1',
        address_line_2                => 'ADDR 2',
        address_city                  => 'Segamat',
        address_state                 => 'State',
        address_postcode              => '85010',
        phone                         => '+60123456789',
        secret_question               => "Mother's maiden name",
        secret_answer                 => BOM::Platform::Client::Utility::encrypt_secret_answer('mei mei'),
        myaffiliates_token_registered => 0,
        checked_affiliate_exposures   => 0,
    };

    $open_account_details->{'client_password'} = BOM::System::Password::hashpw('123456');

    Test::Exception::lives_ok { $client = BOM::Platform::Client->register_and_return_new_client($open_account_details) } "create new client success";
    dies_ok { BOM::Platform::Client->register_and_return_new_client($open_account_details) } 'client duplicates accounts not allowed';
    my $new_loginid = $client->loginid;

    # Test save method
    $client = BOM::Platform::Client::get_instance({'loginid' => $new_loginid});
    $client->first_name('Amy');
    $client->last_name('mimi');
    $client->email('shuwnyuan@betonmarkets.com');
    Test::Exception::lives_ok { $client->save(); } "[save] call client save OK";

    BOM::Platform::Client::get_instance({'loginid' => $new_loginid});
    is($client->first_name, "Amy",                        "[save] client first_name is: Amy");
    is($client->last_name,  "mimi",                       "[save] client last_name is: mimi");
    is($client->email,      'shuwnyuan@betonmarkets.com', '[save] client email is: shuwnyuan@betonmarkets.com');

};

