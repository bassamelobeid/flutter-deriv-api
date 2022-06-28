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
    affiliate_account_add => 1,
    address_city          => "Timbuktu",
    address_line_1        => "Askia Mohammed Bvd,",
    address_postcode      => "QXCQJW",
    address_state         => "Tombouctou",
    country               => "ml",
    data_of_birth         => "1992-01-02",
    first_name            => "John",
    last_name             => "Doe",
    non_pep_declaration   => 1,
    password              => "S3creTp4ssw0rd",
    phone                 => "+72443598863",
    tnc_accepted          => 1,
    username              => "johndoe"
);

my $lc = LandingCompany::Registry->by_broker('AFF');

subtest 'new affiliate account' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test@binary.com',
        client_password => 'abc123',
        residence       => 'au',
    });

    my $res = $t->await::affiliate_account_add(\%details, {timeout => 10});
    test_schema('affiliate_account_add', $res);
    is $res->{msg_type}, "affiliate_account_add";
    delete($res->{echo_req}->{req_id});
    cmp_deeply $res->{echo_req}, \%details;
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
