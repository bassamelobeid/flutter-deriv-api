use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Fatal;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::User;

use BOM::Platform::Context qw(request localize);

use BOM::Event::Actions::Email;
use BOM::Event::Process;

my $brand = Brands->new(name => 'deriv');
my ($app_id) = sort $brand->whitelist_apps->%*;

my (@identify_args, @track_args);

my $rudderstack_response = Future->done(1);
my $mock_segment         = new Test::MockModule('WebService::Async::Segment::Customer');
$mock_segment->redefine(
    'identify' => sub {
        @identify_args = @_;
        return $rudderstack_response;
    },
    'track' => sub {
        @track_args = @_;
        return $rudderstack_response;
    });

my @emit_args;

my $mock_emitter = new Test::MockModule('BOM::Platform::Event::Emitter');
$mock_emitter->mock('emit', sub { push @emit_args, @_ });

my @enabled_brands = ('deriv', 'binary');

my $mock_brands = Test::MockModule->new('Brands');
$mock_brands->mock(
    'is_track_enabled' => sub {
        my $self = shift;
        return (grep { $_ eq $self->name } @enabled_brands);
    });

my $service_contexts = BOM::Test::Customer::get_service_contexts();

my $test_customer = BOM::Test::Customer->create(
    email_verified => 1,
    salutation     => 'MR',
    first_name     => 'John',
    last_name      => 'Wick',
    clients        => [{
            name        => 'CR',
            broker_code => 'CR',
        },
    ]);

subtest 'email events - risk disclaimer resubmission' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    BOM::Event::Actions::Email::send_client_email_track_event({
            language   => 'ES',
            event      => 'risk_disclaimer_resubmission',
            loginid    => $test_customer->get_client_loginid('CR'),
            properties => {
                title        => 'test title',
                loginid      => $test_customer->get_client_loginid('CR'),
                salutation   => $test_customer->get_client_object('CR')->salutation,
                website_name => 'Deriv.com'
            }
        },
        $service_contexts
    )->get;

    my ($customer, %args) = @track_args;

    is $args{event}, 'risk_disclaimer_resubmission', "got correct event name";

    cmp_deeply $args{properties},
        {
        website_name => 'Deriv.com',
        brand        => 'deriv',
        title        => 'test title',
        loginid      => 'CR10000',
        salutation   => 'MR',
        lang         => 'ES',
        },
        'event properties are ok';

    is $args{context}{locale}, 'ES', "got correct preferred language";
};

subtest 'email event - unknown_login' => sub {
    undef @identify_args;
    undef @track_args;

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );
    request($req);

    BOM::Event::Actions::Email::send_client_email_track_event({
            language   => 'EN',
            event      => 'unknown_login',
            loginid    => $test_customer->get_client_loginid('CR'),
            properties => {
                device                    => 'android',
                app_name                  => 'my app',
                is_reset_password_allowed => 0,
                country                   => 'Antarctica',
                title                     => 'New device login',
                first_name                => 'Bob',
                ip                        => '127.0.0.1',
                browser                   => 'chrome',
                password_reset_url        => $req->brand->password_reset_url({
                        website_name => $req->brand->website_name,
                        source       => $app_id,
                        language     => $req->language,
                        app_name     => 'deriv'
                    })}
        },
        $service_contexts
    )->get;

    my ($customer, %args) = @track_args;

    is $args{event}, 'unknown_login', "got correct event name";

    cmp_deeply $args{properties},
        {
        brand                     => 'deriv',
        loginid                   => $test_customer->get_client_loginid('CR'),
        email                     => $test_customer->get_email(),
        lang                      => 'EN',
        device                    => 'android',
        lang                      => 'EN',
        app_name                  => 'my app',
        is_reset_password_allowed => 0,
        country                   => 'Antarctica',
        title                     => 'New device login',
        first_name                => 'Bob',
        ip                        => '127.0.0.1',
        browser                   => 'chrome',
        password_reset_url        => 'https://deriv.com/en/reset-password/'
        },
        'event properties are ok';
};

done_testing;
