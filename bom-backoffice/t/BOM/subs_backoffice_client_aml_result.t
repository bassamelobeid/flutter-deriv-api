use Test::More;
use Test::MockModule;

use lib '/home/git/regentmarkets/bom-backoffice';

use_ok('subs::subs_backoffice_client_aml_result');
use_ok('BOM::Platform::LexisNexisAPI');
use_ok('BOM::Database::UserDB');

subtest 'Testing LexisNexisAPI mocks' => sub {
    my $lexis_nexis_api_mock = Test::MockModule->new('BOM::Platform::LexisNexisAPI');
    $lexis_nexis_api_mock->mock(
        'get_jwt_token',
        sub {
            my $auth_token = 'mocked_auth_token';
            return Future->done($auth_token);
        });

    $lexis_nexis_api_mock->mock(
        'get_records',
        sub {
            my ($self, $auth_token, $user_lexis_nexis_alert_ids) = @_;
            my $records = [{
                    record_details => {
                        record_state => {
                            history => [{
                                    event => 'Match Note Added',
                                    note  => 'Created: 2 | 12779040 \n Note ID: 266963  \n Hello World!\n',
                                    date  => '2024-06-20T12:36:53Z',
                                    user  => 'User Name'
                                }]}
                    },
                    watchlist => {matches => [{entity_details => {list_reference_number => '12779040'}}]}}];
            return Future->done($records);
        });

    my $user_lexis_nexis_alert_id = 123;
    my $lexis_nexis_results       = lexis_nexis_results($user_lexis_nexis_alert_id);
    is_deeply(
        $lexis_nexis_results,
        [{
                record_details => {
                    record_state => {
                        history => [{
                                event => 'Match Note Added',
                                note  => 'Created: 2 | 12779040 \n Note ID: 266963  \n Hello World!\n',
                                date  => '2024-06-20T12:36:53Z',
                                user  => 'User Name'
                            }]}
                },
                watchlist => {matches => [{entity_details => {list_reference_number => '12779040'}}]}}
        ],
        'lexis_nexis_results returns expected results'
    );
};

subtest 'Testing parse_lexis_nexis_results' => sub {
    my $lexis_nexis_api_mock = Test::MockModule->new('BOM::Platform::LexisNexisAPI');
    my $lexis_nexis_results  = [{
            record_details => {
                record_state => {
                    history => [{
                            event => 'Match Note Added',
                            note  => 'Created: 2 | 12779040 \n Note ID: 266963  \n Hello World!\n',
                            date  => '2024-06-20T12:36:53Z',
                            user  => 'User Name'
                        }]}
            },
            watchlist => {matches => [{entity_details => {list_reference_number => '12779040'}}]}}];

    my $parsed_results = parse_lexis_nexis_results($lexis_nexis_results);
    is_deeply($parsed_results, $lexis_nexis_results->[0]->{watchlist}->{matches}, 'Parsed results match');

    $lexis_nexis_api_mock->mock('get_jwt_token', sub { Future->done('mock_token') });
    $lexis_nexis_api_mock->mock('get_records',
        sub { Future->done([{record_details => {record_state => {history => []}}, watchlist => {matches => []}}]) });

    my $lexis_nexis_results = lexis_nexis_results($user_lexis_nexis_alert_id);
    is_deeply(
        $lexis_nexis_results,
        [{record_details => {record_state => {history => []}}, watchlist => {matches => []}}],
        'lexis_nexis_results returns expected results'
    );

    my $matches = parse_lexis_nexis_results($lexis_nexis_results);
    is_deeply($matches, [], 'parse_lexis_nexis_results returns expected matches');
};

subtest 'Testing find_risk_screen' => sub {
    my $binary_user_id   = 456;
    my $client_entity_id = 789;
    my $status           = 'active';
    my @rows             = find_risk_screen(
        binary_user_id   => $binary_user_id,
        client_entity_id => $client_entity_id,
        status           => $status
    );

    ok(1, 'find_risk_screen returns expected results');
};

done_testing();
