use strict;
use warnings;
use utf8;

use Test::More;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;
use await;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_wsapi_test();

my %client_details = (
    new_account_real       => 1,
    salutation             => 'Ms',
    last_name              => 'last-name',
    first_name             => 'first\'name',
    date_of_birth          => '1990-12-30',
    residence              => 'au',
    place_of_birth         => 'de',
    address_line_1         => 'Jalan Usahawan',
    address_line_2         => 'Enterpreneur Center',
    address_city           => 'Sydney',
    address_postcode       => '47120',
    phone                  => '+60321685000',
    secret_question        => 'Favourite dish',
    secret_answer          => 'nasi lemak,teh tarik',
    account_opening_reason => 'Speculative'
);

subtest 'new CR real account' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test@binary.com',
        client_password => 'abc123',
        residence       => 'au',
    });
    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'create CR account' => sub {
        # Note the p.o. box address should not fail the call for CR accounts
        my ($res, $call_params) = call_mocked_consumer_groups_request(
            $t,
            {
                %client_details,
                address_state  => 'Australian Capital Territory',
                address_line_1 => 'p.o. box 25325'
            });
        is $call_params->{token}, $token;
        ok($res->{msg_type}, 'new_account_real');
        ok($res->{new_account_real});
        test_schema('new_account_real', $res);
        my $loginid = $res->{new_account_real}->{client_id};
        like($loginid, qr/^CR\d+$/, "got CR client $loginid");
    };
};

subtest 'create account failed' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+id@binary.com',
        client_password => 'abc123',
        residence       => 'id',
    });
    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    subtest 'Invalid state' => sub {
        my %details = %client_details;
        $details{address_state} = 'Selngor';

        my $res = $t->await::new_account_real(\%details);

        is($res->{error}->{code},    'InvalidState', 'State name does not match the country');
        is($res->{new_account_real}, undef,          'NO account created');
    };

    subtest 'email unverified' => sub {
        $user->update_email_fields(email_verified => 'f');

        # create real acc
        my %details = %client_details;
        $details{residence} = 'id';
        $details{first_name} .= '-id';
        $details{phone} = '+60321685001';

        my $res = $t->await::new_account_real(\%details);

        is($res->{error}->{code},    'email unverified', 'email unverified');
        is($res->{new_account_real}, undef,              'NO account created');
    };

    $user->update_email_fields(email_verified => 't');

    $vr_client->residence('id');
    $vr_client->save;

    subtest 'residence unmatch with Virtual acc' => sub {
        my %details = %client_details;
        $details{residence} = 'au';

        my $res = $t->await::new_account_real(\%details);

        is($res->{error}->{code},    'PermissionDenied', 'cannot create real account');
        is($res->{new_account_real}, undef,              'NO account created');
    };

    subtest 'min age check' => sub {
        my %details = %client_details;
        $details{residence} = 'id';

        my $res = $t->await::new_account_real({%details, date_of_birth => '2008-01-01'});
        is($res->{error}->{code},    'BelowMinimumAge', 'min age unmatch');
        is($res->{new_account_real}, undef,             'NO account created');
    };

    subtest 'insufficient info' => sub {
        # create real acc
        my %details = %client_details;
        $details{residence} = 'id';
        my @missing_properties = qw(first_name last_name);
        delete $details{$_} for @missing_properties;

        my $res = $t->await::new_account_real(\%details);

        is($res->{error}->{code}, 'InsufficientAccountDetails', 'Not enough info');
        is_deeply($res->{error}->{details}, {missing => [@missing_properties]}, 'All missing required properties are listed');
        is($res->{new_account_real}, undef, 'NO account created');
    };

    subtest 'validate whitespace in first_name' => sub {
        my %details = %client_details;
        $details{first_name} = '    ';
        my $res = $t->await::new_account_real(\%details);

        is($res->{error}->{code},    'InputValidationFailed',               "Input field is invalid");
        is($res->{error}->{message}, 'Input validation failed: first_name', "Checked that validation failed for first_name");
    };

    subtest 'validate one chinese character in first_name' => sub {
        $vr_client->residence('cn');
        $vr_client->save;

        my %details = %client_details;
        $details{first_name} = '强';
        $details{last_name}  = '张';
        $details{currency}   = 'USD';
        $details{residence}  = 'cn';

        my $res = $t->await::new_account_real(\%details);
        ok($res->{msg_type}, 'new_account_real');
        is($res->{error}, undef, 'account created successfully');
    };

    subtest 'restricted or invalid country' => sub {
        subtest 'restricted - US' => sub {
            $vr_client->residence('us');
            $vr_client->save;

            my %details = %client_details;
            $details{residence} = 'us';

            my $res = $t->await::new_account_real(\%details);

            is($res->{error}->{code},    'InvalidAccountRegion', 'restricted country - US');
            is($res->{new_account_real}, undef,                  'NO account created');
        };

        subtest 'invalid - xx' => sub {
            $vr_client->residence('xx');
            $vr_client->save;

            my %details = %client_details;
            $details{residence} = 'xx';

            my $res = $t->await::new_account_real(\%details);

            is($res->{error}->{code},    'InvalidAccountRegion', 'invalid country - xx');
            is($res->{new_account_real}, undef,                  'NO account created');
        };

    };

    subtest 'no MF' => sub {
        $vr_client->residence('de');
        $vr_client->save;

        my %details = %client_details;
        $details{residence} = 'de';

        my $res = $t->await::new_account_real(\%details);

        is($res->{error}->{code},    'InvalidAccount', 'wrong acc opening - MF');
        is($res->{new_account_real}, undef,            'NO account created');
    };
};

subtest 'new_real_account with currency provided' => sub {
    # create VR acc
    my ($vr_client, $user) = create_vr_account({
        email           => 'test+111@binary.com',
        client_password => 'abC123',
        residence       => 'au',
    });
    my %details = %client_details;
    $details{salutation} = 'Mr';

    my $compiled_checks = sub {
        my ($res, $details) = @_;
        my $loginid = $res->{new_account_real}->{client_id};

        ok($res->{msg_type}, 'new_account_real');
        ok($res->{new_account_real});
        test_schema('new_account_real', $res);
        like($loginid, qr/^CR\d+$/, "got CR client $loginid");
        is($res->{new_account_real}->{currency}, $details->{currency}, "currency set as per request");
    };

    # authorize
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});

    $details{currency}  = 'USD';
    $details{last_name} = 'Torvalds';
    $details{phone}     = '+60321685007';
    my $res = $t->await::new_account_real(\%details);
    $compiled_checks->($res, \%details);

    # now let's login as a real account and try to create more accounts
    $token = $res->{new_account_real}->{oauth_token};
    $t->await::authorize({authorize => $token});

    $res = $t->await::new_account_real(\%details);

    is($res->{error}->{code}, 'DuplicateCurrency', 'Second account with the same currency is not allowed');

    $details{currency} = 'LTC';
    $res = $t->await::new_account_real(\%details);
    $compiled_checks->($res, \%details);

    $details{currency} = 'ETH';
    $res = $t->await::new_account_real(\%details);
    $compiled_checks->($res, \%details);

    $details{currency} = 'XXX';
    $res = $t->await::new_account_real(\%details);
    is($res->{error}->{code}, 'CurrencyNotApplicable', 'Try to create account with incorrect currency');
};

subtest 'validate phone field' => sub {
    my %details = %client_details;
    $details{date_of_birth} = '1999-01-01';

    subtest 'phone can be empty' => sub {
        my ($vr_client, $user) = create_vr_account({
            email           => 'emptyness+111@binary.com',
            client_password => 'abC123',
            residence       => 'br',
        });

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});

        $details{currency}   = 'USD';
        $details{residence}  = 'br';
        $details{first_name} = 'i dont have';
        $details{last_name}  = 'a phone number';
        $details{salutation} = 'Miss';
        delete $details{phone};

        my $res = $t->await::new_account_real(\%details);
        ok($res->{msg_type},         'new_account_real');
        ok($res->{new_account_real}, 'new account created with empty phone');
    };

    subtest 'user can enter invalid or dummy phone number' => sub {
        my ($vr_client, $user) = create_vr_account({
            email           => 'dummy-phone-number@binary.com',
            client_password => 'abC123',
            residence       => 'br',
        });

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});

        $details{currency}   = 'USD';
        $details{residence}  = 'br';
        $details{first_name} = 'dummy-phone';
        $details{last_name}  = 'ownerian';
        $details{phone}      = '+1234-864116586523';

        my $res = $t->await::new_account_real(\%details);
        ok($res->{msg_type}, 'new_account_real');
        is($res->{error}, undef, 'account created successfully with a dummy phone number');
    };

    subtest 'no alphabetic characters are allowed in the phone number' => sub {
        my ($vr_client, $user) = create_vr_account({
            email           => 'alpha-phone-number@binary.com',
            client_password => 'abC123',
            residence       => 'br',
        });

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});

        $details{currency}   = 'USD';
        $details{residence}  = 'br';
        $details{first_name} = 'alphabetic';
        $details{last_name}  = 'phone-number';
        $details{phone}      = '+1234-86x4116586523';    # contains `x` in the middle

        my $res = $t->await::new_account_real(\%details);
        is($res->{error}->{code}, 'InvalidPhone', 'phone number can not contain alphabetic characters.');
    };
    subtest 'more than one special characters are not allowed in a row' => sub {
        my ($vr_client, $user) = create_vr_account({
            email           => 'multiple-special-characters@binary.com',
            client_password => 'abC123',
            residence       => 'br',
        });

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
        $t->await::authorize({authorize => $token});

        $details{currency}   = 'USD';
        $details{residence}  = 'br';
        $details{first_name} = 'alphabetic';
        $details{last_name}  = 'phone-number';
        $details{phone}      = '+1234-8641165++++86523';    # contains more than 3 special characters in a row

        my $res = $t->await::new_account_real(\%details);
        is($res->{error}->{code}, 'InvalidPhone', 'phone can not contain more than 3 special characters in a row.');
    };
};

subtest 'Address validation' => sub {
    my ($vr_client, $user) = create_vr_account({
        email           => 'addr@binary.com',
        client_password => 'abc123',
        residence       => 'br',
    });

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);
    $t->await::authorize({authorize => $token});
    my $cli_details = {
        %client_details,
        residence      => 'br',
        salutation     => 'Mrs',
        first_name     => 'Homer',
        last_name      => 'Thompson',
        address_state  => 'São Paulo',
        address_line_1 => '123° Fake Street',
        address_line_2 => '123º Evergreen Terrace',
    };

    my $res = $t->await::new_account_real($cli_details);
    test_schema('new_account_real', $res);
    is $res->{error}, undef, 'account created successfully';
    ok $res->{new_account_real}->{client_id}, 'Loginid is returned';

    my $cli = BOM::User::Client->new({loginid => $res->{new_account_real}->{client_id}});
    is $cli->address_line_1, $cli_details->{address_line_1}, 'Expected address line 1';
    is $cli->address_line_2, $cli_details->{address_line_2}, 'Expected address line 2';
    is $cli->address_state,  'SP',                           'Address state name is converted to state code';
};

sub create_vr_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                residence       => $args->{residence},
                account_type    => 'binary',
                email_verified  => 1,
            },
        });

    return ($acc->{client}, $acc->{user});
}

$t->finish_ok;

done_testing;
