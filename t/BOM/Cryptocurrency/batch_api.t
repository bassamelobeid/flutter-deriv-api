use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;

use BOM::Cryptocurrency::BatchAPI;

subtest 'BOM::Cryptocurrency::BatchAPI' => sub {
    my $batch = BOM::Cryptocurrency::BatchAPI->new();

    throws_ok { $batch->process() } qr/There is no request in the batch/, 'Throws error if batch contains no request.';

    my %args;
    throws_ok { $batch->add_request(%args) } qr/"action" is required but it is missing/, 'Throws error if action is missing.';

    $args{action} = 'address';
    throws_ok { $batch->add_request(%args) } qr/"action" should be in the format of "category\/method": $args{action}/,
        'Throws error if action is not correct.';

    $args{action} = 'address/validate';
    my $id_1 = $batch->add_request(%args);
    like $id_1, qr/^auto-\d+-/, 'Adds the request successfully and returns the auto-generated id.';

    $args{extra_key} = 'some_value';
    throws_ok { $batch->add_request(%args) } qr/Extra keys are not permitted: extra_key/, 'Throws error if extra parameter passed.';

    $args{body} = 'BTC';
    throws_ok { $batch->add_request(%args) } qr/"body" should be hashref/, 'Throws error if body is wrong type.';

    $args{body}       = {currency_code => 'BTC'};
    $args{depends_on} = 'some_id';
    throws_ok { $batch->add_request(%args) } qr/"depends_on" should be arrayref/, 'Throws error if depends_on is wrong type.';

    $args{depends_on} = 'some_id';
    throws_ok { $batch->add_request(%args) } qr/"depends_on" should be arrayref/, 'Throws error if depends_on is wrong type.';

    $args{depends_on} = ['nonexistent_id_1', 'wrong_id_2'];
    throws_ok { $batch->add_request(%args) } qr/"depends_on" contains nonexistent ids: nonexistent_id_1, wrong_id_2/,
        'Throws error if depends_on ids does not exist.';

    %args = (
        id         => $id_1,
        action     => 'transaction/get_list',
        body       => {currency_code => 'BTC'},
        depends_on => [$id_1],
    );
    throws_ok { $batch->add_request(%args) } qr/"id" with the same value already exists: $id_1/, 'Throws error if id is not unique.';

    $args{id} = 'My-Id-2';
    my $id_2 = $batch->add_request(%args);
    is $id_2, $args{id}, 'Adds the request successfully and returns the correct id.';

    throws_ok { $batch->get_response() } qr/There is no response yet/, 'Throws error when getting response before executing the batch.';

    my $batch_response = [{
            id     => $id_1,
            status => 1,
            body   => {
                is_success => 1,
                message    => 'Operation was successful',
            },
        },
        {
            id     => $id_2,
            status => 0,
            body   => {
                error => {
                    code    => 'CryptoBatchError',
                    message => 'Request did not processed due to an issue.',
                },
            },
        },
    ];
    my $mock_api = Test::MockModule->new('BOM::Platform::CryptoCashier::InternalAPI');
    $mock_api->mock(process_batch => sub { return {responses => $batch_response}; });

    my $received_response = $batch->process();
    is_deeply $received_response, $batch_response, 'Invoking execute() returns the correct response.';

    my $expected_response = {map { $_->{id} => $_ } $batch_response->@*};
    my $all_responses     = $batch->get_response();
    is_deeply $all_responses, $expected_response, 'Invoking get_response() with no parameter, returns the correct response.';

    my $responses = $batch->get_response($id_1, $id_2);
    is_deeply $responses->{$id_1}, $expected_response->{$id_1},
        'Invoking get_response() with multiple parameters, returns the correct response for each id (1).';
    is_deeply $responses->{$id_2}, $expected_response->{$id_2},
        'Invoking get_response() with multiple parameters, returns the correct response for each id (2).';

    my $single_response = $batch->get_response($id_1);
    is_deeply $single_response, $expected_response->{$id_1}, 'Returns the correct response for single id (1).';
    $single_response = $batch->get_response($id_2);
    is_deeply $single_response, $expected_response->{$id_2}, 'Returns the correct response for single id (2).';

    my $expected_bodies = {map { $_->{id} => $_->{body} } $batch_response->@*};
    my $all_bodies      = $batch->get_response_body();
    is_deeply $all_bodies, $expected_bodies, 'Invoking get_response_body() with no parameter, returns the correct bodies.';

    my $bodies = $batch->get_response_body($id_1, $id_2);
    is_deeply $bodies->{$id_1}, $expected_bodies->{$id_1},
        'Invoking get_response_body() with multiple parameters, returns the correct body for each id (1).';
    is_deeply $bodies->{$id_2}, $expected_bodies->{$id_2},
        'Invoking get_response_body() with multiple parameters, returns the correct body for each id (2).';

    my $single_body = $batch->get_response_body($id_1);
    is_deeply $single_body, $expected_bodies->{$id_1}, 'Returns the correct body for single id (1).';
    $single_body = $batch->get_response_body($id_2);
    is_deeply $single_body, $expected_bodies->{$id_2}, 'Returns the correct body for single id (2).';

    $mock_api->unmock_all();
};

done_testing;
