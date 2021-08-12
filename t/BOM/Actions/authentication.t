use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use Email::Address::UseXS;
use BOM::Test;
use BOM::Test::Email;
use Test::Exception;
use BOM::Config::Runtime;
use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Platform::Context;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Utility qw(random_email_address);
use JSON::MaybeUTF8 qw(decode_json_utf8);
use BOM::Event::Actions::Authentication;

subtest 'bulk_authentication' => sub {
    my (@lines, @clients, @users);

    my $allow_poi_resubmission = 1;
    my $poi_reason             = "other";
    my $client_authentication  = "NEEDS_ACTION";

    # Create an array of active loginids to be like csv read input.
    for (my $i = 0; $i <= 20; $i++) {
        $users[$i] = BOM::User->create(
            email    => random_email_address,
            password => BOM::User::Password::hashpw('password'));

        # Add a CR client to the user
        $clients[$i] = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $users[$i]->add_client($clients[$i]);
        push @lines, [$clients[$i]->loginid];
    }

    throws_ok { BOM::Event::Actions::Authentication::bulk_authentication() } qr/csv input file should exist/,
        'throw exception when csv input file is not provided';
    throws_ok { BOM::Event::Actions::Authentication::bulk_authentication({'data' => \@lines}) }
    qr/client_authentication or allow_poi_resubmission should exist/,
        'throw exception when client_authentication or allow_poi_resubmission is not provided';
    throws_ok {
        BOM::Event::Actions::Authentication::bulk_authentication({
                'data'                   => \@lines,
                'allow_poi_resubmission' => $allow_poi_resubmission,
                'poi_reason'             => $poi_reason,
                'client_authentication'  => $client_authentication,
                'staff'                  => 'Sarah Aziziyan',
            })
    }
    qr/email to send results does not exist/, 'throw exception when email to send results t is not provided';

    mailbox_clear();
    my $result = BOM::Event::Actions::Authentication::bulk_authentication({
        'data'                   => \@lines,
        'allow_poi_resubmission' => $allow_poi_resubmission,
        'poi_reason'             => $poi_reason,
        'client_authentication'  => $client_authentication,
        'staff'                  => 'Sarah Aziziyan',
        'to_email'               => 'sarah@deriv.com',
        'staff_department'       => 'Compliance',
    });
    ok($result, 'Returns 1 after triggering authentication for users.');

    # It should send an notification email
    my $msg = mailbox_search(subject => qr/Authentication report for /);
    like($msg->{subject}, qr/Authentication report for \d{4}-\d{2}-\d{2}/, qq/report including failures and successes./);

    foreach my $client (@clients) {
        is($client->status->reason('allow_poi_resubmission'), 'other', sprintf("POI is set to other for client (%s).", $client->loginid));
        is($client->authentication_status(),
            'needs_action', sprintf("client_autnetication is set to NEEDS_ACTION for client (%s).", $client->loginid));
    }

};

subtest 'call_authentication_for_MT5_and_DerivX_accounts' => sub {
    my $loginid                = "MTR001122";
    my $client_authentication  = "NEEDS_ACTION";
    my $allow_poi_resubmission = 1;
    my $poi_reason             = "other";
    my $staff                  = "Sarah Aziziyan";
    my $staff_ip               = "127.0.0.1";

    my $result =
        BOM::Event::Actions::Authentication::_authentication($loginid, $client_authentication, $allow_poi_resubmission, $poi_reason, $staff,
        $staff_ip);
    is($result, "MT5/DerivX login IDs are not allowed.", "MT5 login IDs are not allowed.");

    $loginid = "DXD001122";
    $result =
        BOM::Event::Actions::Authentication::_authentication($loginid, $client_authentication, $allow_poi_resubmission, $poi_reason, $staff,
        $staff_ip);
    is($result, "MT5/DerivX login IDs are not allowed.", "DerivX login IDs are not allowed.");

};

done_testing()
