#!/usr/bin/perl
use strict;
use warnings;

#Path has been added to .proverc (-I.)
use subs::subs_backoffice_clientdetails;
use Brands;
use Test::More;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(create_client);
use BOM::User;
use BOM::Platform::Utility qw(verify_reactivation);

subtest '_get_client_phone_country' => sub {
    my $countries_instance = Brands->new(name => 'Binary')->countries_instance->countries;
    my $email              = 'test@binary.com';

# Create VR client
    my $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $email,
        phone       => ''
    });

# Create CR clients in different countries
    my $cr_us_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email,
        phone       => '+15417543010'
    });

    my $cr_uk_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email,
        phone       => '+441234567891'
    });

    my $cr_invalid_code_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email,
        phone       => '000000'
    });

    my $cr_invalid_phone_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email,
        phone       => '+'
    });

    #Test Case 1: VR Client with no phone set
    is(get_client_phone_country($vr_client, $countries_instance),
        'Unknown', "get_client_phone_country() should return 'Unknown' when client is virtual (no phone set)");

    #Test Case 2: Client's phone resolves to a single country (e.g. +1)
    is(get_client_phone_country($cr_us_client, $countries_instance),
        'us', "get_client_phone_country() should return 'us' when client's phone starts with +1");

    #Test Case 3: Client's phone resolves to more than one country (e.g. +44)
    is(get_client_phone_country($cr_uk_client, $countries_instance),
        'gb, im', "get_client_phone_country() should return two countries 'gb, im' when client's phone starts with +44");

    #Test Case 3: Client's phone resolves to no valid country (e.g. +000)
    is(get_client_phone_country($cr_invalid_code_client, $countries_instance),
        'Unknown', "get_client_phone_country() should return value of 'Unknown' when client's phone has invalid code");

    #Test Case 4: Client's phone resolves to invalid phone
    is(get_client_phone_country($cr_invalid_phone_client, $countries_instance),
        'Unknown', "get_client_phone_country() should return value of 'Unknown' when client's phone is invalid");

};

subtest 'Reactivate client' => sub {
    my $user = BOM::User->create(
        email    => 'rest_reactivate@binary.com',
        password => 'Abcd1234'
    );
    my $mock_user = Test::MockModule->new('BOM::User');
    $mock_user->redefine(email_verified => 1);

    my %clients;
    for my $broker (qw/VRTC CR MF/) {
        my $client_enabled = create_client($broker);
        $client_enabled->set_default_account('USD');
        $user->add_client($client_enabled);

        my $client_duplicate_usd = create_client($broker);
        $client_duplicate_usd->set_default_account('USD');
        $client_duplicate_usd->status->set('duplicate_account', 'test', 'test');
        $user->add_client($client_duplicate_usd);

        my $client_duplicate_eur = create_client($broker);
        $client_duplicate_eur->set_default_account('EUR');
        $client_duplicate_eur->status->set('disabled', 'test', 'test');
        $user->add_client($client_duplicate_eur);

        $clients{$broker} = {
            enabled_usd   => $client_enabled,
            duplicate_usd => $client_duplicate_usd,
            duplicate_eur => $client_duplicate_eur,
        };
    }

    for my $client_mf (values $clients{MF}->%*) {
        $client_mf->residence('es');
        $client_mf->save;
    }

    my %test_cases = (
        CR => {
            enabled_usd   => undef,
            duplicate_usd => 'Duplicate Currency',
            duplicate_eur => 'Currency Type Not Allowed',
        },
        MF => {
            enabled_usd   => undef,
            duplicate_usd => 'Financial Account Exists',
            duplicate_eur => 'Financial Account Exists',
        },
        VRTC => {
            enabled_usd   => undef,
            duplicate_usd => 'Virtual Account Exists',
            duplicate_eur => 'Virtual Account Exists',
        },
    );

    for my $broker (qw/CR MF VRTC/) {
        subtest "Testing $broker" => sub {
            for my $account (qw/enabled_usd duplicate_usd duplicate_eur/) {
                my $client = $clients{$broker}->{$account};
                my $error  = $test_cases{$broker}->{$account};
                my $status = $account eq 'enabled_usd' ? '' : 'duplicate_account';
                eval { verify_reactivation($client, $status, $user); };

                if ($@ && ref($@) eq 'HASH') {
                    my $exception_hash = $@;

                    my $error_message = $exception_hash->{error_msg};
                    like $error_message, qr/$error/, "Correct error when trying to reactivate the $broker $account account";
                } else {
                    lives_ok { verify_reactivation($client, $status, $user) } "Verification allows reactivation of the $broker $account account";
                }
            }
        }
    }

};

done_testing();
