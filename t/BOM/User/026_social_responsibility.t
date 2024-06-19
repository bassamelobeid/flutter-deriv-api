use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal qw(exception lives_ok);
use Future;
use List::Util qw(first);

use BOM::User::Client;
use BOM::User::SocialResponsibility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $email = 'social_resp@binary.com';
my $user  = BOM::User->create(
    email    => $email,
    password => "hello",
);

my %details = (
    client_password          => 'hello',
    first_name               => '',
    last_name                => '',
    myaffiliates_token       => '',
    email                    => $email,
    residence                => 'za',
    address_line_1           => '1 sesame st',
    address_line_2           => '',
    address_city             => 'cyberjaya',
    address_state            => '',
    address_postcode         => '',
    phone                    => '',
    secret_question          => '',
    secret_answer            => '',
    non_pep_declaration_time => time,
);

my $vr = $user->create_client(
    %details,
    broker_code => 'VRTC',
);
my $client = $user->create_client(
    %details,
    broker_code => 'CR',
);
$vr->save;
$client->save;
my $id = $user->id;

subtest 'update sr_risk_status' => sub {

    my $update_sr_risk_status;

    lives_ok { $update_sr_risk_status = BOM::User::SocialResponsibility->update_sr_risk_status($id, 'high'); } 'sr_risk_status saved';

    is $update_sr_risk_status, 'high', 'user has set sr_risk_status to high successfully';

    like exception { BOM::User::SocialResponsibility->update_sr_risk_status($id, 'p') }, qr/invalidSocialResponsibilityType/,
        'invalid social responsibility type';

    lives_ok { $update_sr_risk_status = BOM::User::SocialResponsibility->update_sr_risk_status($id, 'problem trader'); }
    'sr_risk_status saved';

    is $update_sr_risk_status, 'problem trader', 'user has set sr_risk_status to problem trader successfully';
};

subtest 'get sr_risk_status' => sub {

    my $sr_risk;

    lives_ok { $sr_risk = BOM::User::SocialResponsibility->get_sr_risk_status($id) } 'get sr_risk_status';

    is $sr_risk, 'problem trader', 'user has sr_risk_status set to problem trader';

    is $client->risk_level_sr, "high", 'social responsibility risk should be high';

    lives_ok { BOM::User::SocialResponsibility->update_sr_risk_status($id, 'manual override high') } 'sr_risk_status saved';

    lives_ok { $sr_risk = BOM::User::SocialResponsibility->get_sr_risk_status($id) } 'get sr_risk_status saved';

    is $sr_risk, 'manual override high', 'user has sr_risk_status set to manual override high';

    is $client->risk_level_sr, "high", 'social responsibility risk should be high';

    lives_ok { $sr_risk = BOM::User::SocialResponsibility->get_sr_risk_status($id) } 'get sr_risk_status saved';

};

done_testing();
