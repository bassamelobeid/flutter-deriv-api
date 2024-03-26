use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Exception;
use Test::MockObject;

use BOM::User::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

subtest 'has_po_box_address' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

    my $user = BOM::User->create(
        email    => $client->loginid . '@deriv.com',
        password => 'secret_pwd'
    )->add_client($client);

    $client->binary_user_id($user->id);
    $client->user($user);
    $client->save;

    ok !BOM::User::Utility::has_po_box_address($client), 'client has physical address';

    my $patterns = BOM::User::Utility::po_box_patterns();
    for my $pattern ($patterns->@*) {
        lives_ok { $client->address_1($pattern . ' 777') } "set address_1 to po box address pattern '$pattern'";
        ok BOM::User::Utility::has_po_box_address($client), 'po box address detected in address line 1';
        $client->address_1('street 123');

        lives_ok { $client->address_2('PY ' . $pattern . ' 777') } "set address_2 to po box address pattern '$pattern'";
        ok BOM::User::Utility::has_po_box_address($client), 'po box address detected in address line 2';
        $client->address_2('big avenue');
    }

    lives_ok { $client->address_1('OPO OBOX STREET 777') } 'set address_1 to contain po box address pattern';
    ok !BOM::User::Utility::has_po_box_address($client), 'client has physical address, only match complete words';
};

done_testing();
