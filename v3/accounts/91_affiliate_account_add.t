use strict;
use warnings;
use Test::More;
use Test::Deep;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;
use await;

## do not send email
use LandingCompany::Registry;
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_wsapi_test();

my %details = (
    affiliate_account_add  => 1,
    salutation             => 'Ms',
    last_name              => 'last-name',
    first_name             => 'first\'name',
    date_of_birth          => '1990-12-30',
    residence              => 'au',
    place_of_birth         => 'de',
    address_line_1         => 'Jalan Usahawan',
    address_line_2         => 'Enterpreneur Center',
    address_city           => 'Cyberjaya',
    address_state          => 'Selangor',
    address_postcode       => '47120',
    phone                  => '+60321685000',
    secret_question        => 'Favourite dish',
    secret_answer          => 'nasi lemak,teh tarik',
    account_opening_reason => 'Speculative',
    affiliate_plan         => 'turnover',
);

my $lc = LandingCompany::Registry->by_broker('AFF');

subtest 'new affiliate account' => sub {
    my $res = $t->await::affiliate_account_add(\%details, {timeout => 10});

    test_schema('affiliate_account_add', $res);

    is $res->{error}->{code}, 'AuthorizationRequired', 'This endpoint requires authorization';

    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test@binary.com',
        client_password => 'abc123',
        residence       => 'au',
    });
    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    $res = $t->await::affiliate_account_add(\%details, {timeout => 10});
    cmp_deeply $res->{affiliate_account_add},
        {
        oauth_token               => re('^a1-.+$'),
        landing_company           => $lc->name,
        currency                  => 'USD',
        landing_company_shortcode => $lc->short,
        client_id                 => re('^AFF[0-9]+$'),
        };
};

sub create_vr_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                residence       => $args->{residence},
            },
            email_verified => 1
        });

    return ($acc->{client}, $acc->{user});
}

$t->finish_ok;

done_testing;
