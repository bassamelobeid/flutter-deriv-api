use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal qw(exception lives_ok);
use Test::MockTime;
use Test::MockModule;
use Syntax::Keyword::Try;
use Future;
use List::Util qw(first);
use IO::Async::Loop;
use Date::Utility;
use WebService::Async::LexisNexis::MockServer;

use BOM::Platform::LexisNexisAPI;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use WebService::Async::LexisNexis::Utility     qw(remap_keys);

my %mock_data = ();
my $mock_yaml = Test::MockModule->new('YAML');
$mock_yaml->redefine(LoadFile => sub { return \%mock_data; });

my $loop = IO::Async::Loop->new;
$loop->add(my $server = WebService::Async::LexisNexis::MockServer->new(mock_data_path => 'Dummy'));
my $port = $server->start->get;
ok $port, 'A port number is returned';

my $user_cr = BOM::User->create(
    email    => 'lexis_nexis_cr@binary.com',
    password => "hello",
);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user_cr->id,
});
my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user_cr->id,
});
$user_cr->add_client($client_cr);
$user_cr->add_client($client_cr2);

my $user_mf = BOM::User->create(
    email    => 'lexis_nexis_mf@binary.com',
    password => "hello",
);
my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MF',
    binary_user_id => $user_mf->id,
});
$user_mf->add_client($client_mf);

my $user_mf2 = BOM::User->create(
    email    => 'lexis_nexis_mf2@binary.com',
    password => "hello",
);
my $client_mf2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MF',
    binary_user_id => $user_mf2->id,
});
$user_mf2->add_client($client_mf2);

my $user_mf3 = BOM::User->create(
    email    => 'lexis_nexis_mf3@binary.com',
    password => "hello",
);
my $client_mf3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MF',
    binary_user_id => $user_mf3->id,
});
$user_mf3->add_client($client_mf3);

my %lexis_nexis_config = (
    api_url    => 'http://localhost',
    api_key    => 'dummy',
    port       => $port,
    auth_token => "dummy"
);
my $mock_config = Test::MockModule->new('BOM::Config');
$mock_config->redefine(third_party => sub { return {lexis_nexis => \%lexis_nexis_config}; });

subtest 'get_user_by_interface_reference' => sub {
    my $lexis_nexis_api = BOM::Platform::LexisNexisAPI->new();
    my $result          = $lexis_nexis_api->get_user_by_interface_reference();
    is $result, undef, 'No client with empty interface ref';

    $result = $lexis_nexis_api->get_user_by_interface_reference('xyz');
    is $result, undef, 'No client with invalid interface ref';

    $result = $lexis_nexis_api->get_user_by_interface_reference($client_cr->loginid);
    isa_ok $result, 'BOM::User', 'Object type is correct';
    is $result->id, $user_cr->id, 'Correct userid';

    for my $str ('123', 'PA+', 'bc123') {
        $result = $lexis_nexis_api->get_user_by_interface_reference($str . $client_cr->loginid);
        isa_ok $result, 'BOM::User', "Object type is correct for prefix $str";
        is $result->id, $user_cr->id, "Correct userid for prefix $str";
    }

    for my $str (' 123', '+PA', '+bc123', "+1234") {
        $result = $lexis_nexis_api->get_user_by_interface_reference($client_cr->loginid . $str);
        isa_ok $result, 'BOM::User', "Object type is correct for suffix $str";
        is $result->id, $user_cr->id, "Correct userid for suffix $str";
    }
};

subtest 'get_jwt_token' => sub {
    my $lexis_nexis_api = BOM::Platform::LexisNexisAPI->new();
    %mock_data = (JwtToken => {access_token => "dummy"});
    my $result;
    lives_ok { $result = $lexis_nexis_api->get_jwt_token()->get } 'get_jwt_token method successfully executed';
    is_deeply $result, $mock_data{JwtToken}->{access_token}, 'Correct token value is returned';
};

subtest 'get_runs_ids' => sub {
    my $lexis_nexis_api = BOM::Platform::LexisNexisAPI->new();
    %mock_data = (
        Runs => [{
                RunID               => 10000001,
                NumRecordsProcessed => 1
            },
            {
                RunID               => 10000002,
                NumRecordsProcessed => 1
            },
            {
                RunID               => 20000000,
                NumRecordsProcessed => -1
            }]);
    my $result;
    lives_ok { $result = $lexis_nexis_api->get_runs_ids("dummy", "08-03-2023", "07-03-2023")->get } 'get_runs_ids method successfully executed';
    is_deeply $result, [10000001, 10000002], 'Correct run ids were returned';
};

subtest 'get_record_ids' => sub {
    my $lexis_nexis_api = BOM::Platform::LexisNexisAPI->new();
    %mock_data = (

        RecordIds => [{
                RunID    => 10000001,
                RecordID => 300001
            },
            {
                RunID    => 10000002,
                RecordID => 300002
            },
        ]);
    my $result;
    lives_ok { $result = $lexis_nexis_api->get_record_ids("dummy", {run_ids => [10000001, 10000002]})->get }
    'get_record_ids method successfully executed';
    is_deeply $result, [300001, 300002], 'Correct record ids were returned';
};

subtest 'get_records' => sub {
    my $lexis_nexis_api = BOM::Platform::LexisNexisAPI->new();
    %mock_data = (
        Runs => [{
                RunID               => 10000001,
                NumRecordsProcessed => 1
            },
            {
                RunID               => 10000002,
                NumRecordsProcessed => 1
            },
            {
                RunID               => 20000000,
                NumRecordsProcessed => -1
            }
        ],
        RecordIds => [{
                RunID    => 10000001,
                RecordID => 300001
            },
            {
                RunID    => 10000002,
                RecordID => 300002
            },
        ],
        Records => [{
                RecordDetails => {
                    IDs => {
                        Number => "CR90000003",
                        Type   => "Account"
                    },
                    LastUpdatedDate => "2022-12-30T11:11:26Z",
                    RecordState     => {
                        History => [{
                                Event => "Alert Decision Applied",
                                Note  => "UNDETERMINED decision was applied",
                            },
                            {
                                Event => "New Note",
                                Note  => "MT5 BVI"
                            },
                        ],
                    },
                    SearchDate => "2022-12-30T10:53:50Z",
                },
                ResultID => 300001,
            },
            {
                RecordDetails => {
                    IDs => {
                        Number => "CR90000004",
                        Type   => "Account"
                    },
                    LastUpdatedDate => "2022-12-31T11:11:26Z",
                    RecordState     => {
                        History => [{
                                Event => "Alert Decision Applied",
                                Note  => "ACCEPT decision was applied",
                            },
                            {
                                Event => "New Note",
                                Note  => "MT5 BVI"
                            },
                        ],
                    },
                    SearchDate => "2022-12-31T10:53:50Z",
                },
                ResultID => 300002,
            },
        ]);

    my $result;
    lives_ok { $result = $lexis_nexis_api->get_records("dummy", [300001, 300002])->get } 'get_records method successfully executed';

    my $mock_data = remap_keys('snake', $mock_data{Records});
    is_deeply $result, $mock_data, 'Correct records were returned';
};

subtest 'get_all_client_records' => sub {
    my $update_all      = 0;
    my $count           = 0;
    my $lexis_nexis_api = BOM::Platform::LexisNexisAPI->new(
        update_all => $update_all,
        count      => $count
    );

    %mock_data = (
        JwtToken => {access_token => "dummy"},
        Runs     => [{
                RunID               => 10000001,
                NumRecordsProcessed => 1
            },
            {
                RunID               => 10000002,
                NumRecordsProcessed => 1
            },
            {
                RunID               => 20000000,
                NumRecordsProcessed => -1
            }
        ],
        RecordIds => [{
                RunID    => 10000001,
                RecordID => 300001
            },
            {
                RunID    => 10000002,
                RecordID => 300002
            },
        ],
        Records => [{
                RecordDetails => {
                    IDs => {
                        Number => "CR90000003",
                        Type   => "Account"
                    },
                    LastUpdatedDate => "2022-12-30T11:11:26Z",
                    RecordState     => {
                        History => [{
                                Event => "Alert Decision Applied",
                                Note  => "UNDETERMINED decision was applied",
                            },
                            {
                                Event => "New Note",
                                Note  => "MT5 BVI"
                            },
                        ],
                    },
                    SearchDate => "2022-12-30T10:53:50Z",
                },
                ResultID => 300001,
            },
            {
                RecordDetails => {
                    IDs => {
                        Number => "CR90000004",
                        Type   => "Account"
                    },
                    LastUpdatedDate => "2022-12-31T11:11:26Z",
                    RecordState     => {
                        History => [{
                                Event => "Alert Decision Applied",
                                Note  => "ACCEPT decision was applied",
                            },
                            {
                                Event => "New Note",
                                Note  => "MT5 BVI"
                            },
                        ],
                    },
                    SearchDate => "2022-12-31T10:53:50Z",
                },
                ResultID => 300002,
            },
        ]);

    my @result;
    my $date_start = Date::Utility->new()->date_ddmmyyyy();
    lives_ok { @result = $lexis_nexis_api->get_all_client_records($date_start)->get } 'get_all_client_records method successfully executed';

    my $mock_data = remap_keys('snake', $mock_data{Records});
    is_deeply \@result, $mock_data, 'Correct all client records were returned';
};

subtest 'sync_all_customers' => sub {
    my $update_all      = 0;
    my $count           = 0;
    my $lexis_nexis_api = BOM::Platform::LexisNexisAPI->new(
        update_all => $update_all,
        count      => $count
    );

    %mock_data = (
        JwtToken => {access_token => "dummy"},
        Runs     => [{
                RunID               => 10000001,
                NumRecordsProcessed => 1
            },
            {
                RunID               => 10000002,
                NumRecordsProcessed => 1
            },
            {
                RunID               => 10000003,
                NumRecordsProcessed => 1
            },
            {
                RunID               => 10000004,
                NumRecordsProcessed => 1
            },
            {
                RunID               => 20000000,
                NumRecordsProcessed => -1
            }
        ],
        RecordIds => [{
                RunID    => 10000001,
                RecordID => 300001
            },
            {
                RunID    => 10000002,
                RecordID => 300002
            },
            {
                RunID    => 10000003,
                RecordID => 300003
            },
            {
                RunID    => 10000004,
                RecordID => 300004
            },
        ],
        Records => [{
                RecordDetails => {
                    AdditionalInfo => [{
                            Label => "client_loginid",
                            Type  => "Other",
                            Value => "CR10000"
                        }
                    ],
                    LastUpdatedDate => "2022-12-30T11:11:26Z",
                    RecordState     => {
                        History => [{
                                Event => "Alert Decision Applied",
                                Note  => "UNDETERMINED decision was applied",
                            },
                            {
                                Event => "New Note",
                                Note  => "MT5 BVI"
                            },
                        ],
                        Status => "false positive"
                    },
                    SearchDate => "2022-12-30T10:53:50Z",
                },
                ResultID  => 300001,
                Watchlist => {
                    Matches => [{
                            EntityDetails => {DateListed => "2012-10-29"},
                            DateModified  => "2013-09-19T00:00:00Z",
                            ResultDate    => "2022-12-29T08:19:45Z"
                        }]}
            },
            {
                RecordDetails => {
                    AdditionalInfo => [{
                            Label => "client_loginid",
                            Type  => "Other",
                            Value => "MF90000000"
                        }
                    ],
                    LastUpdatedDate => "2022-12-31T11:11:26Z",
                    RecordState     => {
                        History => [{
                                Event => "Alert Decision Applied",
                                Note  => "ACCEPT decision was applied",
                            },
                            {
                                Event => "New Note",
                                Note  => "MT5 BVI"
                            },
                        ],
                        Status => "positive match"
                    },
                    SearchDate => "2022-12-31T10:53:50Z",
                },
                ResultID  => 300002,
                Watchlist => {
                    Matches => [{
                            EntityDetails => {DateListed => "2015-10-29"},
                            DateModified  => "2016-09-19T00:00:00Z",
                            ResultDate    => "2022-12-29T08:19:45Z"
                        }]}
            },
            {
                RecordDetails => {
                    AdditionalInfo => [{
                            Label => "client_loginid",
                            Type  => "Other",
                            Value => "MF90000001"
                        }
                    ],
                    LastUpdatedDate => "2023-12-22T11:11:26Z",
                    RecordState     => {
                        History => [{
                                Event => "Alert Decision Applied",
                                Note  => "UNDETERMINED decision was applied",
                            },
                            {
                                Event => "New Note",
                                Note  => "MT5 BVI"
                            },
                        ],
                        Status => "False Match_Config"
                    },
                    SearchDate => "2023-12-22T10:53:50Z",
                },
                ResultID  => 300003,
                Watchlist => {
                    Matches => [{
                            EntityDetails => {DateListed => "2015-10-05"},
                            DateModified  => "2016-09-19T00:00:00Z",
                            ResultDate    => "2022-12-05T08:19:45Z"
                        }]}
            },
            {
                RecordDetails => {
                    AdditionalInfo => [{
                            Label => "client_loginid",
                            Type  => "Other",
                            Value => "MF90000002"
                        }
                    ],
                    LastUpdatedDate => "2023-12-12T11:11:26Z",
                    RecordState     => {
                        History => [{
                                Event => "Alert Decision Applied",
                                Note  => "ACCEPT decision was applied",
                            },
                            {
                                Event => "New Note",
                                Note  => "MT5 BVI"
                            },
                        ],
                        Status => "potential match"
                    },
                    SearchDate => "2023-12-12T10:53:50Z",
                },
                ResultID  => 300004,
                Watchlist => {
                    Matches => [{
                            EntityDetails => {DateListed => "2015-10-29"},
                            DateModified  => "2016-09-15T00:00:00Z",
                            ResultDate    => "2022-12-07T08:19:45Z"
                        }]}
            },
        ]);

    my $result;
    lives_ok { $result = $lexis_nexis_api->sync_all_customers()->get } 'get_all_client_records method successfully executed';
    is $result, 1, 'The returned value is correct';

    is_deeply(
        $user_cr->lexis_nexis,
        {
            'alert_id'       => 300001,
            'alert_status'   => "false positive",
            'binary_user_id' => 1,
            'client_loginid' => $client_cr->loginid,
            'date_added'     => "2022-12-30",
            'date_updated'   => "2022-12-29",
            'note'           => "MT5 BVI",
        },
        'CR LexisNexis profile is saved correctly'
    );

    is_deeply(
        $user_mf->lexis_nexis,
        {
            'alert_id'       => 300002,
            'alert_status'   => "positive match",
            'binary_user_id' => 2,
            'client_loginid' => $client_mf->loginid,
            'date_added'     => "2022-12-31",
            'date_updated'   => "2022-12-29",
            'note'           => "MT5 BVI",
        },
        'MF LexisNexis profile is saved correctly'
    );

    is_deeply(
        $user_mf2->lexis_nexis,
        {
            'alert_id'       => 300003,
            'alert_status'   => "false match config",
            'binary_user_id' => 3,
            'client_loginid' => $client_mf2->loginid,
            'date_added'     => "2023-12-22",
            'date_updated'   => "2022-12-05",
            'note'           => "MT5 BVI",
        },
        'MF LexisNexis profile is saved correctly'
    );
    is_deeply(
        $user_mf3->lexis_nexis,
        {
            'alert_id'       => 300004,
            'alert_status'   => "potential match",
            'binary_user_id' => 4,
            'client_loginid' => $client_mf3->loginid,
            'date_added'     => "2023-12-12",
            'date_updated'   => "2022-12-07",
            'note'           => "MT5 BVI",
        },
        'MF LexisNexis profile is saved correctly'
    );
};

done_testing();
