use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::RPC::QueueClient;
use Business::Config::Country::Registry;

my $c = BOM::Test::RPC::QueueClient->new();

my $method = 'tin_validations';

subtest 'TIN validations' => sub {

    subtest 'invalid tax residence' => sub {
        my $result            = $c->call_ok($method, {args => {tax_residence => undef}})->has_no_system_error->result;
        my $expected_response = {
            code              => 'InputValidationFailed',
            message_to_client => 'Invalid tax residence selected. Please select a valid tax residence.'
        };

        cmp_deeply($result->{error}, $expected_response, 'Expected error response for undefined tax residence.');

        $result            = $c->call_ok($method, {args => {tax_residence => 'invalid'}})->has_no_system_error->result;
        $expected_response = {
            code              => 'InputValidationFailed',
            message_to_client => 'Invalid tax residence selected. Please select a valid tax residence.'
        };

        cmp_deeply($result->{error}, $expected_response, 'Expected error response for invalid tax residence.');
    };

    subtest 'valid tax residence' => sub {

        my $country_config      = Business::Config::Country::Registry->new()->list();
        my $country_config_keys = [keys %$country_config];

        foreach (@$country_config_keys) {
            my $result = $c->call_ok($method, {args => {tax_residence => $_}})->has_no_system_error->result;
            delete $result->{stash};

            is($result->{error}, undef, 'No error for valid tax residence ' . $_);

            my $expected_response = {
                invalid_patterns             => ignore(),
                is_tin_mandatory             => ignore(),
                tin_employment_status_bypass => ignore(),
                tin_format                   => ignore(),
            };

            cmp_deeply $result, $expected_response, 'Expected result for TIN validations for ' . $_;
        }

    };
};

done_testing();
