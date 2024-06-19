use strict;
use warnings;

use Test::Most;
use BOM::User::Utility;
use BOM::User::Client;
use Text::Trim qw( trim );

# Set up test input data
my $test_args = {
    first_name                => ' Containing ',
    last_name                 => 'Spaces ',
    address_line_1            => 'Nice building ',
    address_line_2            => ' nice street  ',
    address_city              => ' Dubai ',
    tax_identification_number => '12341241235  ',
    address_postcode          => '123 ',
    secret_answer             => ' Answer should not be trimmed ',
    secret_question           => ' Question should not be trimmed '
};

my @immutable_fields = BOM::User::Client::PROFILE_FIELDS_IMMUTABLE_DUPLICATED->@*;
my %immutable_fields = map { $_ => 1 } @immutable_fields;

subtest 'verify only immutable fields are trimmed' => sub {
    my $response_args = BOM::User::Utility::trim_immutable_client_fields($test_args);
    for my $key (keys %$test_args) {
        # If it is an immutable field, verify that the trimmed values and returned values are equal
        if (exists($immutable_fields{$key})) {
            ok(trim($test_args->{$key}) eq $response_args->{$key}, "Immutable key $key is trimmed");
        } else {
            ok($test_args->{$key} eq $response_args->{$key} && trim($test_args->{$key}) ne $response_args->{$key}, "Mutable key $key is not trimmed");
        }
    }
};

done_testing();
