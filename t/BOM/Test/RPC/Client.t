use strict;
use warnings;

use Test::More;
use Test::MockObject::Extends;
use Test::Warnings;
use BOM::Test::RPC::Client;

subtest 'Checking response without error object' => sub {
    my %value_for = (
        has_no_error                => '1',
        has_error                   => '',
        error_code_is               => undef,
        error_message_is            => undef,
        error_internal_message_like => undef,
        error_message_like          => undef,
        error_details_is            => undef,
    );

    for my $method (keys %value_for) {
        my %response_for = (
            HashRef  => {},
            Undef    => undef,
            ArrayRef => [],
            Scalar   => 'some string',
        );
        for my $type (keys %response_for) {
            my $client = BOM::Test::RPC::Client->new(
                result => $response_for{$type},
                params => ['some_request'],
                ua     => undef,
            );

            $client = Test::MockObject::Extends->new($client);

            my $extracted_value;
            $client->mock(_test => sub { $extracted_value = $_[2]; return 1; });
            $client->$method();
            is $extracted_value, $value_for{$method}, "Got expected value from $method for $type response";
        }
    }
};

subtest 'Checking response with error object' => sub {
    my %value_for = (
        has_no_error                => '',
        has_error                   => '1',
        error_code_is               => 'some error code',
        error_message_is            => 'some message to client',
        error_internal_message_like => 'some message',
        error_message_like          => 'some message to client',
        error_details_is            => {some_key => 'some value'},
    );

    for my $method (keys %value_for) {
        my $client = BOM::Test::RPC::Client->new(
            result => {
                error => {
                    code              => 'some error code',
                    message_to_client => 'some message to client',
                    message           => 'some message',
                    details           => {some_key => 'some value'},
                },
            },
            params => ['some_request'],
            ua     => undef,
        );

        $client = Test::MockObject::Extends->new($client);

        my $extracted_value;
        $client->mock(_test => sub { $extracted_value = $_[2]; return 1; });
        $client->$method();
        is_deeply $extracted_value, $value_for{$method}, "Got expected value from $method";
    }
};

done_testing;
