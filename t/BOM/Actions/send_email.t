use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Fatal;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;

use BOM::Platform::Context qw(request);

use BOM::Event::Actions::Email;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

$client->email('test@deriv.com');
$client->salutation('MR');
$client->save;

my $user = BOM::User->create(
    email          => $client->email,
    password       => "hello",
    email_verified => 1,
)->add_client($client);

my $brand = Brands->new(name => 'deriv');
my ($app_id) = $brand->whitelist_apps->%*;

my $mock_segment = new Test::MockModule('WebService::Async::Segment::Customer');
$mock_segment->redefine(
    'track' => sub {
        return Future->done(1);
    });

my $mock_track = Test::MockModule->new('BOM::Event::Services::Track');
my $track_event_properties;
$mock_track->mock(
    '_send_track_request',
    sub {
        my ($customer, $properties, $event, $brand) = @_;
        $track_event_properties = $properties;
        return Future->done(1);
    },
    '_validate_params',
    sub {
        return $client;
    },
    'track_event',
    sub {
        return $mock_track->original('track_event')->(@_);
    });

my @enabled_brands = ('deriv', 'binary');

my $mock_brands = Test::MockModule->new('Brands');
$mock_brands->mock(
    'is_track_enabled' => sub {
        my $self = shift;
        return (grep { $_ eq $self->name } @enabled_brands);
    });

my $req = BOM::Platform::Context::Request->new(
    brand_name => 'deriv',
    language   => 'EN',
    app_id     => $app_id,
);
request($req);

subtest 'send_email with request context language (default)' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    BOM::Event::Actions::Email::send_email_generic({
            event      => 'test_event_1',
            loginid    => $client->loginid,
            properties => {
                prop1 => 'hello',
                prop2 => 'world',
            }})->get;

    is $track_event_properties->{lang}, 'EN', "track event properties has the request context language";
};

subtest 'send_email with user preferred language' => sub {
    $user->update_preferred_language('RU');    # set preferred_language

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    BOM::Event::Actions::Email::send_email_generic({
            event      => 'test_event_2',
            loginid    => $client->loginid,
            properties => {
                prop1 => 'hello',
                prop2 => 'world',
            }})->get;

    is $track_event_properties->{lang}, 'RU', "track event properties has the user preferred language";
};

subtest 'send_email with explicit language' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    BOM::Event::Actions::Email::send_email_generic({
            language   => 'ES',               # force a language
            event      => 'test_event_3',
            loginid    => $client->loginid,
            properties => {
                prop1 => 'hello',
                prop2 => 'world',
            }})->get;

    is $track_event_properties->{lang}, 'ES', "track event properties has the explicitly set language";
};

done_testing();
