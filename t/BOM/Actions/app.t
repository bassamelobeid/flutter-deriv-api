use strict;
use warnings;

use Test::More;
use Test::Warnings qw(warning);
use Test::Fatal;
use Test::MockModule;

use WebService::Async::Segment::Customer;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::Request;
use BOM::Event::Actions::App;
use BOM::User;
use Time::Moment;
use Date::Utility;
use BOM::Platform::Locale qw/get_state_by_id/;
use BOM::Event::Process;

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'test1@bin.com',
});

my $email = $test_client->email;
my $user  = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);

$user->add_client($test_client);

my (@identify_args, @track_args);
my $segment_response = Future->done(1);
my $mock_segment     = new Test::MockModule('WebService::Async::Segment::Customer');
$mock_segment->redefine(
    'identify' => sub {
        @identify_args = @_;
        return $segment_response;
    },
    'track' => sub {
        @track_args = @_;
        return $segment_response;
    });
my $mock_brands = Test::MockModule->new('Brands');
$mock_brands->mock(
    'is_track_enabled' => sub {
        my $self = shift;
        return ($self->name eq 'deriv');
    });

subtest 'app registered' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $args = {
        loginid          => $test_client->loginid,
        app_id           => 1,
        name             => 'App 1',
        scopes           => ['read', 'trade'],
        redirect_uri     => 'https://www.example.com/',
        verification_uri => 'https://www.example.com/verify',
        homepage         => 'https://www.homepage.com/',
    };
    my $handler = BOM::Event::Process::get_action_mappings()->{app_registered};
    my $result  = $handler->($args)->get;
    is $result, 1, 'Success track result';
    is scalar @identify_args, 0, 'no identify call';

    my ($customer, %args) = @track_args;
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'app_registered',
        properties => $args,
        },
        'track context and properties are properly set.';

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'id'
    );
    request($req);
    undef @track_args;

    $result = $handler->($args)->get;
    is $result, undef, 'empty track result (not called)';
    is scalar @identify_args, 0, 'no identify call';
    is scalar @track_args,    0, 'no track call';
};

subtest 'app updated' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $args = {
        loginid    => $test_client->loginid,
        app_id     => 1,
        name       => 'App 2',
        googleplay => 'https://googleplay.com/app_2',
        homepage   => 'https://www.homepage.com/',
    };
    my $handler = BOM::Event::Process::get_action_mappings()->{app_updated};
    my $result  = $handler->($args)->get;
    is $result, 1, 'Success track result';
    is scalar @identify_args, 0, 'no identify call';

    my ($customer, %args) = @track_args;
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'app_updated',
        properties => $args,
        },
        'track context and properties are properly set.';

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'id'
    );
    request($req);
    undef @track_args;

    $result = $handler->($args)->get;
    is $result, undef, 'Empty track result';
    is scalar @identify_args, 0, 'no identify call';
    is scalar @track_args,    0, 'no track call';
};

subtest 'app deleted' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $args = {
        loginid => $test_client->loginid,
        app_id  => 1,
    };
    my $handler = BOM::Event::Process::get_action_mappings()->{app_deleted};
    my $result  = $handler->($args)->get;
    is $result, 1, 'Success track result';
    is scalar @identify_args, 0, 'no identify call';

    my ($customer, %args) = @track_args;
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'app_deleted',
        properties => $args,
        },
        'track context and properties are properly set.';

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'id'
    );
    request($req);
    undef @track_args;

    $result = $handler->($args)->get;
    is $result, undef, 'Empty track result';
    is scalar @identify_args, 0, 'no identify call';
    is scalar @track_args,    0, 'no track call';
};

done_testing();
