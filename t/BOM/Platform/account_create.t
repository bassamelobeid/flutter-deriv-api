use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;
use BOM::Platform::Client::Utility;
use BOM::Platform::Account::Virtual;
use BOM::Platform::Account::Real::default;
use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

BOM::Platform::Runtime->instance->app_config->system->on_production(1);

my $vr_acc = BOM::Platform::Account::Virtual::create_account({ details => {
    email           => 'foo+us@binary.com',
    client_password => 'foobar',
    residence       => 'us',     # US
}});
is($vr_acc->{error}, 'invalid', 'create VR acc failed: restricted country');

my $vr_details = {
    CR => {
        email           => 'foo+id@binary.com',
        client_password => 'foobar',
        residence       => 'id',            # Indonesia
    },
    MLT => {
        email           => 'foo+nl@binary.com',
        client_password => 'foobar',
        residence       => 'nl',            # Netherlands
    },
    MX => {
        email           => 'foo+gb@binary.com',
        client_password => 'foobar',
        residence       => 'gb',             # UK
    },
};

foreach my $broker (keys %$vr_details) {
    my ($vr_acc, $real_acc, $vr_client, $real_client, $user);
    lives_ok {
        $vr_acc = BOM::Platform::Account::Virtual::create_account({ details => $vr_details->{$broker} });
        ($vr_client, $user) = @{$vr_acc}{'client', 'user'};
    } 'create VR acc';

    my %real_client_details = (
        salutation                      => 'Ms',
        last_name                       => 'binary',
        date_of_birth                   => '1990-01-01',
        address_line_1                  => 'address 1',
        address_line_2                  => 'address 2',
        address_city                    => 'city',
        address_state                   => 'state',
        address_postcode                => '89902872',
        phone                           => '82083808372',
        secret_question                 => 'Mother\'s maiden name',
        secret_answer                   => 'sjgjdhgdjgdj',,
        myaffiliates_token_registered   => 0,
        checked_affiliate_exposures     => 0,
        latest_environment              => '',
    );
    $real_client_details{$_} = $vr_details->{$broker}->{$_} for qw(email residence);
    $real_client_details{$_} = $broker for qw(broker_code first_name);
    $real_client_details{client_password} = $vr_client->password;

    my $real_params = {
        from_client => $vr_client,
        user        => $user,
        details     => \%real_client_details,
        country     => $vr_client->residence,
    };

    lives_ok { $real_acc = BOM::Platform::Account::Real::default::create_account($real_params); } "create $broker acc";
    is($real_acc->{error}, 'email unverified', "create $broker acc failed: email verification required");

    $user->email_verified(1);
    $user->save;

    lives_ok { $real_acc = BOM::Platform::Account::Real::default::create_account($real_params); } "create $broker acc OK, after verify email";
    is($real_acc->{client}->broker, $broker, 'Successfully create ' . $real_acc->{client}->loginid);

    lives_ok { $real_acc = BOM::Platform::Account::Real::default::create_account($real_params); } "Try create duplicate $broker acc";
    is($real_acc->{error}, 'duplicate email', "Create duplicate $broker acc failed");
}

BOM::Platform::Runtime->instance->app_config->system->on_production(0);
