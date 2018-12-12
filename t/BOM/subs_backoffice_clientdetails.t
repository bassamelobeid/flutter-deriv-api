#!/usr/bin/perl
use strict;
use warnings;

#Path has been added to .proverc (-I.)
use subs::subs_backoffice_clientdetails;
use Brands;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::More;

my $countries_instance = Brands->new(name => 'Binary')->countries_instance->countries;
my $email = 'test@binary.com';

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
    phone       => '+112123121'
});

my $cr_uk_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email,
    phone       => '+441234567891'
});

my $cr_invalid_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email,
    phone       => '+999234567891'
});

subtest '_get_client_phone_country' => sub {

    #Test Case 1: VR Client with no phone set
    is(get_client_phone_country($vr_client, $countries_instance),
        'Unknown', "get_client_phone_country() should return 'Unknown' when client is virtual (no phone set)");

    #Test Case 2: Client's phone resolves to a single country (e.g. +1)
    is(get_client_phone_country($cr_us_client, $countries_instance),
        'us', "get_client_phone_country() should return 'us' when client's phone starts with +1");

    #Test Case 3: Client's phone resolves to more than one country (e.g. +44)
    is(get_client_phone_country($cr_uk_client, $countries_instance),
        'gb, im', "get_client_phone_country() should return single country 'gb, im' when client's phone starts with +1");

    #Test Case 3: Client's phone resolves to no valid country (e.g. +999)
    is(get_client_phone_country($cr_invalid_client, $countries_instance),
        'Unknown', "get_client_phone_country() should return single country 'Unknown' when client's phone has invalid code");

};

done_testing();
