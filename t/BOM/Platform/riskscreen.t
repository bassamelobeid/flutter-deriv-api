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
use WebService::Async::RiskScreen::MockServer;

use BOM::Platform::RiskScreenAPI;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my %mock_data = ();
my $mock_yaml = Test::MockModule->new('YAML');
$mock_yaml->redefine(LoadFile => sub { return \%mock_data; });

my $loop = IO::Async::Loop->new;
$loop->add(my $server = WebService::Async::RiskScreen::MockServer->new(mock_data_path => 'Dummy'));
my $port = $server->start->get;
ok $port, 'A port number is returned';

my $user_cr = BOM::User->create(
    email    => 'riskscreen_cr@binary.com',
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
    email    => 'riskscreen_mf@binary.com',
    password => "hello",
);
my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MF',
    binary_user_id => $user_mf->id,
});
$user_mf->add_client($client_mf);

my %riskscreen_config = (
    api_url => 'http://localhost',
    api_key => 'dummy',
    port    => $port
);
my $mock_config = Test::MockModule->new('BOM::Config');
$mock_config->redefine(third_party => sub { return {risk_screen => \%riskscreen_config}; });

subtest 'get_user_by_interface_reference' => sub {
    my $riskscreen_api = BOM::Platform::RiskScreenAPI->new();
    my $result         = $riskscreen_api->get_user_by_interface_reference();
    is $result, undef, 'No client with empty interface ref';

    $result = $riskscreen_api->get_user_by_interface_reference('xyz');
    is $result, undef, 'No client with invalid interface ref';

    $result = $riskscreen_api->get_user_by_interface_reference($client_cr->loginid);
    isa_ok $result, 'BOM::User', 'Object type is correct';
    is $result->id, $user_cr->id, 'Correct userid';

    for my $str ('123', 'PA+', 'bc123') {
        $result = $riskscreen_api->get_user_by_interface_reference($str . $client_cr->loginid);
        isa_ok $result, 'BOM::User', "Object type is correct for prefix $str";
        is $result->id, $user_cr->id, "Correct userid for prefix $str";
    }

    for my $str (' 123', '+PA', '+bc123', "+1234") {
        $result = $riskscreen_api->get_user_by_interface_reference($client_cr->loginid . $str);
        isa_ok $result, 'BOM::User', "Object type is correct for suffix $str";
        is $result->id, $user_cr->id, "Correct userid for suffix $str";
    }
};

subtest 'get_udpated_riskscreen_customers' => sub {
    my $riskscreen_api = BOM::Platform::RiskScreenAPI->new();
    %mock_data = ();
    my @result;
    lives_ok { @result = $riskscreen_api->get_udpated_riskscreen_customers()->get } 'No error with empty customer list';
    is_deeply \@result, [], 'There is no customer';

    %mock_data = (
        Customers => [{
                InterfaceReference => 'INVALID',
                ClientEntityID     => 1234,
                StatusID           => 1
            }]);
    lives_ok { @result = $riskscreen_api->get_udpated_riskscreen_customers()->get } 'No error for invalid customers';
    is_deeply \@result, [], 'There is no valid customer';

    push $mock_data{Customers}->@*,
        {
        InterfaceReference => $client_cr->loginid,
        ClientEntityID     => 100,
        StatusID           => 1,
        DateAdded          => '2020-01-01'
        };
    lives_ok { @result = $riskscreen_api->get_udpated_riskscreen_customers()->get } 'No error for a single customer';
    is_deeply \@result, [$client_cr->loginid], 'One customer is returned';
    is_deeply [$user_cr->risk_screen->@{qw(status client_entity_id interface_reference)}], ['active', 100, $client_cr->loginid];

    # push a newer customer
    push $mock_data{Customers}->@*,
        {
        InterfaceReference => $client_cr2->loginid,
        ClientEntityID     => 101,
        StatusID           => 1,
        DateAdded          => '2021-01-01'
        };
    lives_ok { @result = $riskscreen_api->get_udpated_riskscreen_customers()->get } 'No error for a single customer';
    is_deeply \@result, [$client_cr2->loginid], 'The newer customer is picked';
    is_deeply [$user_cr->risk_screen->@{qw(status client_entity_id interface_reference)}], ['active', 101, $client_cr2->loginid];

    $mock_data{Customers}->[2]->{StatusID} = 0;
    @result = $riskscreen_api->get_udpated_riskscreen_customers()->get;
    is_deeply \@result, [$client_cr->loginid], 'Only the active customer is selected';
    is_deeply [$user_cr->risk_screen->@{qw(status client_entity_id interface_reference)}], ['active', 100, $client_cr->loginid];

    $mock_data{Customers}->[1]->{StatusID} = 0;
    @result = $riskscreen_api->get_udpated_riskscreen_customers()->get;
    is_deeply \@result, [$client_cr2->loginid], 'The newer customer is selected even if both are disabled';
    is_deeply [$user_cr->risk_screen->@{qw(status client_entity_id interface_reference)}], ['disabled', 101, $client_cr2->loginid];

    my $mf_customer = {
        InterfaceReference => $client_mf->loginid,
        ClientEntityID     => 102,
        StatusID           => 1,
        DateAdded          => '2019-09-09',
    };
    push $mock_data{Customers}->@*, $mf_customer;
    lives_ok { @result = $riskscreen_api->get_udpated_riskscreen_customers()->get } 'No error for a single customer';
    is_deeply \@result, [$client_mf->loginid], 'Only the new customer is returned';
    is_deeply [$user_mf->risk_screen->@{qw(status client_entity_id interface_reference)}], ['active', 102, $client_mf->loginid];

    subtest 'Script arguments and failed clients' => sub {
        is_deeply [$riskscreen_api->get_udpated_riskscreen_customers()->get], [], 'There is no new client';

        $riskscreen_api = BOM::Platform::RiskScreenAPI->new(update_all => 1);
        @result         = $riskscreen_api->get_udpated_riskscreen_customers()->get;
        is_deeply \@result, [$client_cr2->loginid, $client_mf->loginid], 'All clients returned with update_all argument';

        $riskscreen_api = BOM::Platform::RiskScreenAPI->new(
            update_all => 1,
            count      => 1
        );
        @result = $riskscreen_api->get_udpated_riskscreen_customers()->get;
        is_deeply \@result, [$client_cr2->loginid], 'Only one client is returned with $count=1';

        $riskscreen_api = BOM::Platform::RiskScreenAPI->new(
            update_all => 1,
            count      => 2
        );
        @result = $riskscreen_api->get_udpated_riskscreen_customers()->get;
        is_deeply \@result, [$client_cr2->loginid, $client_mf->loginid], 'Two clientsreturned with $count=2';

        $mf_customer->{Fail} = 1;
        @result = $riskscreen_api->get_udpated_riskscreen_customers()->get;
        is_deeply \@result, [$client_cr2->loginid, $client_mf->loginid],
            'Failed client is not filtered out (Failed flag is only used by mock server)';
    };
};

subtest 'update_customer_match_details' => sub {
    my $riskscreen_api = BOM::Platform::RiskScreenAPI->new();
    Test::MockTime::set_absolute_time('2012-06-01');

    %mock_data = ();
    lives_ok { $riskscreen_api->update_customer_match_details()->get } 'No error with empty customer list';

    %mock_data = (
        Customers => [{
                InterfaceReference => $client_cr->loginid,
                ClientEntityID     => 201,
                StatusID           => 1,
                DateAdded          => '2010-01-01',
                CustomText1        => 'custom 1'
            },
            {
                InterfaceReference => $client_mf->loginid,
                ClientEntityID     => 202,
                StatusID           => 0,
                DateAdded          => '2019-09-09',
                CustomText1        => 'Payment Agent'
            }
        ],

        Matches => [{
                InterfaceReference => $client_cr->loginid,
                Type               => 'Potential',
                Date               => '2019-09-01'
            },
            {
                InterfaceReference => $client_cr->loginid,
                Type               => 'Discounted',
                Date               => '2019-09-01'
            },
            {
                InterfaceReference => $client_cr->loginid,
                Type               => 'Discounted',
                Date               => '2019-09-01'
            },
            {
                InterfaceReference => $client_mf->loginid,
                Type               => 'Flagged',
                Flag               => 'flag1',
                Date               => '2019-10-01'
            },
            {
                InterfaceReference => $client_mf->loginid,
                Type               => 'Flagged',
                Flag               => 'flag2',
                Date               => '2019-10-01'
            },
            {
                InterfaceReference => $client_mf->loginid,
                Type               => 'Flagged',
                Flag               => 'flag1',
                Date               => '2019-10-01'
            },
        ],
    );
    my @customers = $riskscreen_api->get_udpated_riskscreen_customers()->get;
    is scalar @customers, 2, 'Two new customers';

    is_deeply $user_cr->risk_screen,
        {
        'binary_user_id'          => $user_cr->id,
        'client_entity_id'        => 201,
        'date_updated'            => undef,
        'flags'                   => undef,
        'interface_reference'     => $client_cr->loginid,
        'match_discounted_volume' => undef,
        'match_flagged_volume'    => undef,
        'match_potential_volume'  => undef,
        'status'                  => 'active',
        'custom_text1'            => undef,
        'date_added'              => '2010-01-01',
        },
        'Riskscreen matches are empty for the CR user';

    is_deeply $user_mf->risk_screen,
        {
        'binary_user_id'          => $user_mf->id,
        'client_entity_id'        => 202,
        'date_updated'            => undef,
        'flags'                   => undef,
        'interface_reference'     => $client_mf->loginid,
        'match_discounted_volume' => undef,
        'match_flagged_volume'    => undef,
        'match_potential_volume'  => undef,
        'status'                  => 'disabled',
        'custom_text1'            => 'Payment Agent',
        'date_added'              => '2019-09-09',
        },
        'Riskscreen matches are empty for the MF user';

    lives_ok { $riskscreen_api->update_customer_match_details(@customers)->get } 'No error for two customers without matches';
    is_deeply(
        $user_cr->risk_screen,
        {
            'binary_user_id'          => $user_cr->id,
            'client_entity_id'        => 201,
            'date_updated'            => '2019-09-01',
            'flags'                   => [],
            'interface_reference'     => $client_cr->loginid,
            'match_discounted_volume' => 2,
            'match_flagged_volume'    => 0,
            'match_potential_volume'  => 1,
            'status'                  => 'active',
            'custom_text1'            => undef,
            'date_added'              => '2010-01-01',
        },
        'CR risksreen is saved correctly'
    );
    is_deeply(
        $user_mf->risk_screen,
        {
            'binary_user_id'          => $user_mf->id,
            'client_entity_id'        => 202,
            'date_updated'            => '2019-10-01',
            'flags'                   => ['flag1', 'flag2'],
            'interface_reference'     => $client_mf->loginid,
            'match_discounted_volume' => 0,
            'match_flagged_volume'    => 3,
            'match_potential_volume'  => 0,
            'status'                  => 'disabled',
            'custom_text1'            => 'Payment Agent',
            'date_added'              => '2019-09-09',
        },
        'MF risksreen is saved correctly'
    );

    # Failed status (for simulating failed api calls in mock server)
    is $riskscreen_api->get_udpated_riskscreen_customers()->get, undef, 'There is no updated customer';

    $riskscreen_api = BOM::Platform::RiskScreenAPI->new(update_all => 1);
    @customers      = $riskscreen_api->get_udpated_riskscreen_customers()->get;
    is scalar @customers, 2, 'Two customers are existing in total';

    $mock_data{Customers}->[0]->{Fail} = 1;
    $riskscreen_api = BOM::Platform::RiskScreenAPI->new(update_all => 0);
    $riskscreen_api->update_customer_match_details(@customers)->get;
    is $user_cr->risk_screen->{status}, 'outdated', 'Failed client is marked  as <outdated>. It will be processed in the next round.';

    @customers = $riskscreen_api->get_udpated_riskscreen_customers()->get;
    is_deeply \@customers, [$client_cr->loginid], 'Outdated client appears among the updated customers';

    Test::MockTime::restore_time();
};

subtest 'sync_all_customers' => sub {
    my $riskscreen_api = BOM::Platform::RiskScreenAPI->new();
    my $user           = BOM::User->create(
        email    => 'riskscreen_user1@binary.com',
        password => "hello",
    );
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id,
    });
    $user->add_client($client);

    my $user2 = BOM::User->create(
        email    => 'riskscreen_user2@binary.com',
        password => "hello",
    );
    my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user2->id,
    });
    $user2->add_client($client2);

    lives_ok { $riskscreen_api->sync_all_customers()->get } 'No error with empty args';

    %mock_data = (
        Customers => [{
                InterfaceReference => 'INVALID',
                ClientEntityID     => 12345,
                StatusID           => 1
            }]);
    lives_ok { $riskscreen_api->sync_all_customers()->get } 'No error if interface ref is invalid';

    %mock_data = (
        Customers => [{
                InterfaceReference => $client->loginid,
                ClientEntityID     => 301,
                StatusID           => 1,
                DateAdded          => '2018-01-01',
            }
        ],
        Matches => [{
                InterfaceReference => $client->loginid,
                Type               => 'Discounted',
                Date               => '2019-10-10'
            }
        ],
    );

    my %expected_data = (
        'binary_user_id'          => $user->id,
        'client_entity_id'        => 301,
        'interface_reference'     => $client->loginid,
        'status'                  => 'active',
        'date_updated'            => '2019-10-10',
        'match_potential_volume'  => 0,
        'match_discounted_volume' => 0,
        'match_flagged_volume'    => 0,
        'flags'                   => [],
        'custom_text1'            => undef,
        'date_added'              => '2018-01-01',
    );
    $riskscreen_api->sync_all_customers()->get;
    $expected_data{match_discounted_volume} = 1;
    is_deeply $user->risk_screen, \%expected_data, 'Risksreen is initialized correctly';

    # match dates out of range
    $mock_data{Matches} = [{
            InterfaceReference => $client->loginid,
            Type               => 'Potential',
            # it is before the max date_updated
            Date => '2019-10-09'
        },
        {
            InterfaceReference => $client->loginid,
            Type               => 'Potential',
            # it is after today
            Date => Date::Utility->new->plus_time_interval('1d')->date,
        }];
    $riskscreen_api->sync_all_customers()->get;
    is_deeply $user->risk_screen, \%expected_data, 'Nothing is changed: the match dates were out of accepatable range.';

    # accepted match dates
    my $today = Date::Utility->new->date;
    $mock_data{Matches} = [{
            InterfaceReference => $client->loginid,
            Type               => 'Potential',
            Date               => $expected_data{date_updated},
        },
        {
            InterfaceReference => $client->loginid,
            Type               => 'Discounted',
            Date               => '2020-02-02'
        },
        {
            InterfaceReference => $client->loginid,
            Type               => 'Flagged',
            Date               => $today,
            Flag               => 'test flag'
        }];
    $riskscreen_api->sync_all_customers()->get;

    $expected_data{match_potential_volume}  = 1;
    $expected_data{match_discounted_volume} = 1;
    $expected_data{match_flagged_volume}    = 1;
    $expected_data{flags}                   = ['test flag'];
    $expected_data{date_updated}            = $today;
    is_deeply $user->risk_screen, \%expected_data, 'Match with dates between udpate_date and today are accepted';

    # change customer status
    $mock_data{Customers}->[0]->{StatusID} = 0;
    $mock_data{Matches} = [{
            InterfaceReference => $client->loginid,
            Type               => 'Potential',
            Date               => '2019-01-13'
        }];
    $riskscreen_api->sync_all_customers()->get;
    $expected_data{status}                  = 'disabled';
    $expected_data{match_potential_volume}  = 1;
    $expected_data{match_flagged_volume}    = 0;
    $expected_data{match_discounted_volume} = 0;
    $expected_data{date_updated}            = '2019-01-13';
    $expected_data{flags}                   = [];
    is_deeply $user->risk_screen, \%expected_data, 'Matches are refreshed, because status was changed';

    # new customer entity id
    my $new_entity_id = $mock_data{Customers}->[0]->{ClientEntityID} += 1;
    $mock_data{Customers}->[0]->{ClientEntityID} = $new_entity_id;
    push $mock_data{Matches}->@*,,
        {
        InterfaceReference => $client->loginid,
        Type               => 'Discounted',
        Date               => '2019-01-14'
        };
    $riskscreen_api->sync_all_customers()->get;

    $expected_data{client_entity_id}        = $new_entity_id;
    $expected_data{match_potential_volume}  = 1;
    $expected_data{match_discounted_volume} = 1;
    $expected_data{date_updated}            = '2019-01-14';
    is_deeply $user->risk_screen, \%expected_data, 'Everything is refreshed because client entity id was changed';

    subtest 'script arguments' => sub {
        my $riskscreen_api        = BOM::Platform::RiskScreenAPI->new();
        my $risk_screen1          = {$user->risk_screen->%*};
        my $expected_risk_screen1 = $risk_screen1;

        %mock_data = (
            Customers => [{
                    InterfaceReference => $client->loginid,
                    ClientEntityID     => $risk_screen1->{client_entity_id},
                    StatusID           => 0,
                    DateAdded          => $risk_screen1->{date_added},
                },
                {
                    InterfaceReference => $client2->loginid,
                    ClientEntityID     => 501,
                    StatusID           => 1,
                    DateAdded          => '2000-11-11',
                }
            ],
            Matches => [{
                    InterfaceReference => $client->loginid,
                    Type               => 'Potential',
                    Date               => '2001-01-01'
                },
                {
                    InterfaceReference => $client->loginid,
                    Type               => 'Potential',
                    Date               => '2001-01-01'
                },
                {
                    InterfaceReference => $client2->loginid,
                    Type               => 'Potential',
                    Date               => '2001-01-01'
                },
            ],
        );

        $riskscreen_api->sync_all_customers()->get;
        is_deeply $user->risk_screen, $expected_risk_screen1, 'Matches of the first user are not processed, because they are too old';

        my $expected_risk_screen2 = {
            'binary_user_id'          => $user2->id,
            'client_entity_id'        => 501,
            'interface_reference'     => $client2->loginid,
            'status'                  => 'active',
            'date_updated'            => '2001-01-01',
            'match_potential_volume'  => 1,
            'match_discounted_volume' => 0,
            'match_flagged_volume'    => 0,
            'flags'                   => [],
            'custom_text1'            => undef,
            'date_added'              => '2000-11-11'
        };
        is_deeply $user2->risk_screen, $expected_risk_screen2, 'Matches of the second user2 are processed, because it is a new profile';

        is $riskscreen_api->get_udpated_riskscreen_customers()->get, undef, 'No uppdated customers';

        $riskscreen_api = BOM::Platform::RiskScreenAPI->new(update_all => 1);
        $mock_data{Matches}->[2]->{Date} = '2000-10-10';
        is_deeply [$riskscreen_api->get_udpated_riskscreen_customers()->get], [$client->loginid, $client2->loginid], 'No uppdated customers';

        $riskscreen_api->sync_all_customers()->get;
        $expected_risk_screen1->{match_potential_volume}  = 2;
        $expected_risk_screen1->{match_discounted_volume} = 0;
        $expected_risk_screen1->{match_flagged_volume}    = 0;
        $expected_risk_screen1->{date_updated}            = '2001-01-01';
        is_deeply $user->risk_screen, $expected_risk_screen1, 'Matches of the first user are updated with updpate_all option';
        $expected_risk_screen2->{date_updated} = '2000-10-10';
        is_deeply $user2->risk_screen, $expected_risk_screen2, 'Matches of the second user are updated with updpate_all option';

        $riskscreen_api = BOM::Platform::RiskScreenAPI->new(
            update_all => 1,
            count      => 1
        );
        $_->{Date} = '2000-09-09' for $mock_data{Matches}->@*;
        $riskscreen_api->sync_all_customers()->get;
        $expected_risk_screen1->{date_updated} = '2000-09-09';
        is_deeply $user->risk_screen,  $expected_risk_screen1, 'Matches of the first user are updated with updpate_all and count = 1 options';
        is_deeply $user2->risk_screen, $expected_risk_screen2, 'Matches of the second user are not updated with count = 1';

        $riskscreen_api = BOM::Platform::RiskScreenAPI->new(
            update_all => 1,
            count      => 2
        );
        $_->{Date} = '2000-09-19' for $mock_data{Matches}->@*;
        $riskscreen_api->sync_all_customers()->get;
        $expected_risk_screen1->{date_updated} = '2000-09-19';
        $expected_risk_screen2->{date_updated} = '2000-09-19';
        is_deeply $user->risk_screen,  $expected_risk_screen1, 'Matches of the first user are updated with updpate_all and count = 2 options';
        is_deeply $user2->risk_screen, $expected_risk_screen2, 'Matches of the second user are updated with count = 2';

        # outdated status
        $user->set_risk_screen(status => 'outdated');
        $_->{Date} = '2000-12-12' for $mock_data{Matches}->@*;
        $riskscreen_api = BOM::Platform::RiskScreenAPI->new();
        $riskscreen_api->sync_all_customers()->get;
        $expected_risk_screen1->{date_updated} = '2000-12-12';
        is_deeply $user->risk_screen,  $expected_risk_screen1, 'Matches of the first user are updated because of the <outdated> status';
        is_deeply $user2->risk_screen, $expected_risk_screen2, 'Matches of the second user are not updated';
    };
};

done_testing();
