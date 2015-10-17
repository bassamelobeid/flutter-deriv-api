use Test::More;
use Test::Exception;
use BOM::Platform::Account::Virtual;
use BOM::Platform::MyAffiliates::TrackingHandler;

my $restricted = {
    email     => 'foo@test.com',
    password  => 'foobar',
    residence => 'us',     # US
};

my $accounts = {
    CR => {
        email       => 'foo@testing.com',
        password    => 'foobar',
        residence   => 'id',            # Indonesia
        first_name  => 'CR',
        broker_code => 'CR',
    },
    MLT => {
        email       => 'foo@test123.com',
        password    => 'foobar',
        residence   => 'nl',            # Netherlands
        first_name  => 'MLT',
        broker_code => 'MLT',
    },
    MX => {
        email       => 'foo2@binary.com',
        password    => 'foobar',
        residence   => 'gb',             # UK
        first_name  => 'MX',
        broker_code => 'MX',
    },
};

my $real_client_details = {
#   client_password => $from_client->password,
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
    secret_answer                   => BOM::Platform::Client::Utility::encrypt_secret_answer('mother name'),
    myaffiliates_token_registered   => 0,
    checked_affiliate_exposures     => 0,
    latest_environment              => '',
};


BOM::Platform::Account::Virtual::create_account({ details => {
    %$_,
    aff_token => BOM::Platform::MyAffiliates::TrackingHandler->new->myaffiliates_token,
    env => 'testing',
}});



lives_ok( sub {
ok(BOM::Platform::Account::Virtual::create_account({
        details => {
            %$_,
            aff_token => BOM::Platform::MyAffiliates::TrackingHandler->new->myaffiliates_token,
            env => 'testing',
        }}), "$_->{email} created") 
}, "$_->{email} lives") for @accounts;

done_testing;
