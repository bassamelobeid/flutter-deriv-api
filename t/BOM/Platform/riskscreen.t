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
    my $result = BOM::Platform::RiskScreenAPI::get_user_by_interface_reference();
    is $result, undef, 'No client with empty interface ref';

    $result = BOM::Platform::RiskScreenAPI::get_user_by_interface_reference('xyz');
    is $result, undef, 'No client with invalid interface ref';

    $result = BOM::Platform::RiskScreenAPI::get_user_by_interface_reference($client_cr->loginid);
    isa_ok $result, 'BOM::User', 'Object type is correct';
    is $result->id, $user_cr->id, 'Correct userid';

    for my $str ('123', 'PA+', 'bc123') {
        $result = BOM::Platform::RiskScreenAPI::get_user_by_interface_reference($str . $client_cr->loginid);
        isa_ok $result, 'BOM::User', "Object type is correct for prefix $str";
        is $result->id, $user_cr->id, "Correct userid for prefix $str";
    }

    for my $str (' 123', '+PA', '+bc123', "+1234") {
        $result = BOM::Platform::RiskScreenAPI::get_user_by_interface_reference($client_cr->loginid . $str);
        isa_ok $result, 'BOM::User', "Object type is correct for suffix $str";
        is $result->id, $user_cr->id, "Correct userid for suffix $str";
    }
};

subtest 'get_new_riskscreen_customers' => sub {
    %mock_data = ();
    my @result;

    lives_ok { @result = BOM::Platform::RiskScreenAPI::get_new_riskscreen_customers()->get } 'No error with empty customer list';
    is_deeply \@result, [], 'There is no customer';

    %mock_data = (
        Customers => [{
                InterfaceReference => 'INVALID',
                ClientEntityID     => 1234,
                StatusID           => 1
            }]);
    lives_ok { @result = BOM::Platform::RiskScreenAPI::get_new_riskscreen_customers()->get } 'No error for invalid customers';
    is_deeply \@result, [], 'There is no valid customer';

    push $mock_data{Customers}->@*,
        {
        InterfaceReference => $client_cr->loginid,
        ClientEntityID     => 100,
        StatusID           => 1,
        DateAdded          => '2020-01-01'
        };
    lives_ok { @result = BOM::Platform::RiskScreenAPI::get_new_riskscreen_customers()->get } 'No error for a single customer';
    is_deeply \@result, [$client_cr->loginid], 'One customer is returned';

    # push a newer customer
    push $mock_data{Customers}->@*,
        {
        InterfaceReference => $client_cr2->loginid,
        ClientEntityID     => 101,
        StatusID           => 1,
        DateAdded          => '2021-01-01'
        };
    lives_ok { @result = BOM::Platform::RiskScreenAPI::get_new_riskscreen_customers()->get } 'No error for a single customer';
    is_deeply \@result, [$client_cr2->loginid], 'The newer customer is picked';

    $mock_data{Customers}->[2]->{StatusID} = 0;
    @result = BOM::Platform::RiskScreenAPI::get_new_riskscreen_customers()->get;
    is_deeply \@result, [$client_cr->loginid], 'Only the active customer is selected';

    $mock_data{Customers}->[1]->{StatusID} = 0;
    @result = BOM::Platform::RiskScreenAPI::get_new_riskscreen_customers()->get;
    is_deeply \@result, [$client_cr2->loginid], 'The newer customer is selected even if both are disabled';

    push $mock_data{Customers}->@*,
        {
        InterfaceReference => $client_mf->loginid,
        ClientEntityID     => 102,
        StatusID           => 1,
        DateAdded          => '2019-09-09'
        };
    lives_ok { @result = BOM::Platform::RiskScreenAPI::get_new_riskscreen_customers()->get } 'No error for a single customer';
    is_deeply \@result, [$client_mf->loginid], 'Only the new customer is returned';

    is_deeply [BOM::Platform::RiskScreenAPI::get_new_riskscreen_customers()->get], [], 'There is no new client';
};

subtest 'update_customer_match_details' => sub {
    Test::MockTime::set_absolute_time('2012-06-01');

    %mock_data = ();
    lives_ok { BOM::Platform::RiskScreenAPI::update_customer_match_details()->get } 'No error with empty customer list';

    %mock_data = (
        Customers => [{
                InterfaceReference => $client_cr->loginid,
                ClientEntityID     => 201,
                StatusID           => 1,
                DateAdded          => '2010-01-01',
            },
            {
                InterfaceReference => $client_mf->loginid,
                ClientEntityID     => 202,
                StatusID           => 0,
                DateAdded          => '2019-09-09',
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
    my @customers = BOM::Platform::RiskScreenAPI::get_new_riskscreen_customers()->get;
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
        'status'                  => 'active'
        },
        'Riskscreen is empty for the CR user';
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
        'status'                  => 'disabled'
        },
        'Riskscreen is empty for the MF user';

    lives_ok { BOM::Platform::RiskScreenAPI::update_customer_match_details(@customers)->get } 'No error for two customers without matches';
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
            'status'                  => 'active'
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
            'status'                  => 'disabled'
        },
        'MF risksreen is saved correctly'
    );

    Test::MockTime::restore_time();
};

subtest 'sync_all_customers' => sub {
    my $user = BOM::User->create(
        email    => 'riskscreen_user1@binary.com',
        password => "hello",
    );
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id,
    });
    $user->add_client($client);

    BOM::Platform::RiskScreenAPI::sync_all_customers()->get;
    lives_ok { BOM::Platform::RiskScreenAPI::sync_all_customers()->get } 'No error with required args';

    %mock_data = (
        Customers => [{
                InterfaceReference => 'INVALID',
                ClientEntityID     => 12345,
                StatusID           => 1
            }]);
    lives_ok { BOM::Platform::RiskScreenAPI::sync_all_customers()->get } 'No error if interface ref is invalid';

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
    );
    BOM::Platform::RiskScreenAPI::sync_all_customers()->get;
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
    BOM::Platform::RiskScreenAPI::sync_all_customers()->get;
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
    BOM::Platform::RiskScreenAPI::sync_all_customers()->get;

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
    BOM::Platform::RiskScreenAPI::sync_all_customers()->get;
    $expected_data{status} = 'disabled';
    is_deeply $user->risk_screen, \%expected_data, 'Status is updated, but matching data was not changed (match was too old)';

    # new customer entity id
    my $new_entity_id = $mock_data{Customers}->[0]->{ClientEntityID} += 1;
    $mock_data{Customers}->[0]->{ClientEntityID} = $new_entity_id;
    BOM::Platform::RiskScreenAPI::sync_all_customers()->get;

    $expected_data{client_entity_id}        = $new_entity_id;
    $expected_data{match_potential_volume}  = 1;
    $expected_data{match_discounted_volume} = 0;
    $expected_data{match_flagged_volume}    = 0;
    $expected_data{flags}                   = [];
    $expected_data{date_updated}            = '2019-01-13';
    is_deeply $user->risk_screen, \%expected_data, 'Everything is refreshed because client entity id was changed';
};

done_testing();
