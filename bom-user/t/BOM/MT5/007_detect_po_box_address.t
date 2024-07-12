use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Exception;
use Test::MockObject;

use BOM::User::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;

subtest 'has_po_box_address' => sub {
    my $test_customer = BOM::Test::Customer->create(
        clients => [{
                name        => 'CR',
                broker_code => 'CR',
            }]);
    my $client = $test_customer->get_client_object('CR');

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

subtest 'is_po_box_verified' => sub {
    my $test_customer = BOM::Test::Customer->create(
        clients => [{
                name        => 'CR',
                broker_code => 'CR',
            }]);
    my $client = $test_customer->get_client_object('CR');

    ok !BOM::User::Utility::has_po_box_address($client), 'client has physical address';
    ok !$client->fully_authenticated(),                  'client is not fully authenticated';
    ok !$client->is_po_box_verified(),                   'client is not po box verified';

    $client->set_authentication('ID_PO_BOX', {status => 'pass'});
    is $client->authentication_status(), 'po_box', 'client is fully authenticated with ID_PO_BOX method';
    ok !BOM::User::Utility::has_po_box_address($client), 'client has physical address';
    ok $client->is_po_box_verified(),                    'client is po box verified';
    $client->set_authentication('ID_PO_BOX', {status => 'needs_action'});

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    is $client->authentication_status(), 'scans', 'client is authenticated with ID_DOCUMENT method';
    ok !BOM::User::Utility::has_po_box_address($client), 'client has physical address';
    ok !$client->is_po_box_verified({ignore_idv => 1}),  'client is not po box verified';
    $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'});

    $client->address_1('po box 123');
    $client->save();

    $client->set_authentication('IDV_ADDRESS', {status => 'pass'});
    is $client->authentication_status(), 'idv_address', 'client is fully authenticated with IDV_ADDRESS method';
    ok BOM::User::Utility::has_po_box_address($client), 'client has po box address';
    ok $client->is_po_box_verified(),                   'client is po box verified';

    is $client->authentication_status(), 'idv_address', 'client is fully authenticated with IDV_ADDRESS method';
    ok BOM::User::Utility::has_po_box_address($client), 'client has po box address';
    ok !$client->is_po_box_verified({ignore_idv => 1}), 'client is not po box verified when ignore_idv flag set';
    $client->set_authentication('IDV_ADDRESS', {status => 'needs_action'});

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    is $client->authentication_status(), 'scans', 'client is authenticated with ID_DOCUMENT method';
    ok BOM::User::Utility::has_po_box_address($client), 'client has po box address';
    ok $client->is_po_box_verified({ignore_idv => 1}),  'client is po box verified';
};

done_testing();
