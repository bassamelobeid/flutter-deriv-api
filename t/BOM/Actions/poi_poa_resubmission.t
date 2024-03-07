use strict;
use warnings;

use Future;
use Test::More;
use Test::MockModule;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use DataDog::DogStatsd::Helper;

use BOM::User;
use BOM::Platform::Context qw(request);
use BOM::Event::Process;

my $brand = Brands->new(name => 'deriv');
my ($app_id) = $brand->whitelist_apps->%*;

my (@track_args);
my $mock_segment = Test::MockModule->new('WebService::Async::Segment::Customer');

$mock_segment->redefine(
    'track' => sub {
        @track_args = @_;
        return Future->done(1);
    });

my @emit_args;

my $mock_service_config = Test::MockModule->new('BOM::Config::Services');
$mock_service_config->mock(is_enabled => 0);

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $test_user = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);
$test_user->add_client($test_client);
$test_client->residence('co');
$test_client->binary_user_id($test_user->id);
$test_client->save;

my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
my @metrics;
$dog_mock->mock(
    'stats_inc',
    sub {
        push @metrics, @_ if scalar @_ == 2;
        push @metrics, @_, undef if scalar @_ == 1;

        return 1;
    });

subtest 'notify poi resubmission' => sub {

    subtest 'reason unselected' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'unselected',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};

        my $result = $handler->($param);
        ok !$result, 'Email not sent';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, undef, "Event not emitted on unselected reason";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:unselected', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason other' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'other',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};

        my $result = $handler->($param);
        ok !$result, 'Email not sent';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, undef, "Event not emitted on other reason";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:other', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason suspicious' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'suspicious',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poi_reason   => 'suspicious',
            brand        => 'deriv',
            poi_title    => 'Your proof of identity does not meet our verification standards.',
            first_name   => 'bRaD',
            poi_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a valid proof of identity, such as a passport, driving licence, or national identity card, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poi_layout => [
                'bears your name that matches your Deriv profile',
                'shows the date of issue and/or expiry (if applicable)',
                'shows your full date of birth',
                'shows your photo'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:suspicious', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason blurred' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'blurred',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poi_reason   => 'blurred',
            brand        => 'deriv',
            poi_title    => 'Your proof of identity is blurred.',
            first_name   => 'bRaD',
            poi_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a high-resolution, clear, and readable document, such as a passport, driving licence, or national identity card, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poi_layout => [
                'bears your name that matches your Deriv profile',
                'shows the date of issue and/or expiry (if applicable)',
                'shows your full date of birth',
                'shows your photo'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:blurred', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason cropped' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'cropped',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poi_reason   => 'cropped',
            brand        => 'deriv',
            poi_title    => 'Your proof of identity is cropped.',
            first_name   => 'bRaD',
            poi_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a full document, such as a passport, driving licence, or national identity card, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poi_layout => [
                'bears your name that matches your Deriv profile',
                'shows the date of issue and/or expiry (if applicable)',
                'shows your full date of birth',
                'shows your photo'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:cropped', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason expired' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'expired',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poi_reason   => 'expired',
            brand        => 'deriv',
            poi_title    => 'Your proof of identity is expired.',
            first_name   => 'bRaD',
            poi_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a valid document, such as a passport, driving licence, or national identity card, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poi_layout => [
                'bears your name that matches your Deriv profile',
                'shows the date of issue and/or expiry (if applicable)',
                'shows your full date of birth',
                'shows your photo'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:expired', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason type_is_not_valid' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'type_is_not_valid',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poi_reason   => 'type_is_not_valid',
            brand        => 'deriv',
            poi_title    => "The type of document you submitted as proof of identity can't be accepted.",
            first_name   => 'bRaD',
            poi_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a different proof of identity, such as a passport, driving licence, or national identity card, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poi_layout => [
                'bears your name that matches your Deriv profile',
                'shows the date of issue and/or expiry (if applicable)',
                'shows your full date of birth',
                'shows your photo'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:type_is_not_valid', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason selfie_is_not_valid' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'selfie_is_not_valid',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties}, {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poi_reason   => 'selfie_is_not_valid',
            brand        => 'deriv',
            poi_title    => 'The selfie submitted does not show a clear image of your face.',
            first_name   => 'bRaD',
            poi_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a selfie with a clear image of your face which we can verify against the picture in your proof of identity.',
                'You can also submit it together with your proof of identity, such as a passport, driving licence, or national identity card, with the following requirements:'

            ],
            title      => "We couldn't verify your account",
            poi_layout => [
                'bears your name that matches your Deriv profile',
                'shows the date of issue and/or expiry (if applicable)',
                'shows your full date of birth',
                'shows your photo'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:selfie_is_not_valid', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason nimc_no_dob' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'nimc_no_dob',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poi_reason   => 'nimc_no_dob',
            brand        => 'deriv',
            poi_title    => "Your proof of identity doesn't show your date of birth.",
            first_name   => 'bRaD',
            poi_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a document, such as a passport, driving licence, or national identity card, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poi_layout => [
                'bears your name that matches your Deriv profile',
                'shows the date of issue and/or expiry (if applicable)',
                'shows your full date of birth',
                'shows your photo'
            ],
            footnote =>
                'Please reply to this email and attach your birth certificate or submit a different proof of identity that shows your date of birth.'
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:nimc_no_dob', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason different_person_name' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'different_person_name',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poi_reason   => 'different_person_name',
            brand        => 'deriv',
            poi_title    => "The names on your proof of identity and Deriv profile don't match.",
            first_name   => 'bRaD',
            poi_subtitle => [
                'Please go to your profile and ensure your details are accurate. Then, verify/authenticate your account by submitting a proof of identity, such as a passport, driving licence, or national identity card, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poi_layout => [
                'bears your name that matches your Deriv profile',
                'shows the date of issue and/or expiry (if applicable)',
                'shows your full date of birth',
                'shows your photo'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:different_person_name', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason missing_one_side' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poi_reason' => 'missing_one_side',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poi_reason   => 'missing_one_side',
            brand        => 'deriv',
            poi_title    => 'Your proof of identity is missing a front/back section.',
            first_name   => 'bRaD',
            poi_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit your complete proof of identity, such as a passport, driving licence, or national identity card, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poi_layout => [
                'bears your name that matches your Deriv profile',
                'shows the date of issue and/or expiry (if applicable)',
                'shows your full date of birth',
                'shows your photo'
            ],
            footnote =>
                'If you have trouble sending both sides of the document via the link provided, you may reply to this email with an attachment of both the front and back sides of your document.'
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poi.allow_resubmission.reason' => {tags => ['reason:missing_one_side', 'country:COL']},
            },
            'Expected dd metrics';
    };

};

subtest 'notify poa resubmission' => sub {

    subtest 'reason unselected' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'unselected',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};

        my $result = $handler->($param);
        ok !$result, 'Email not sent';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, undef, "Event not emitted on unselected reason";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:unselected', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason other' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'other',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};

        my $result = $handler->($param);
        ok !$result, 'Email not sent';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, undef, "Event not emitted on other reason";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:other', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason forged' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'forged',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};

        my $result = $handler->($param);
        ok !$result, 'Email not sent';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, undef, "Event not emitted on forged reason";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:forged', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason blurred' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'blurred',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poa_reason   => 'blurred',
            brand        => 'deriv',
            poa_title    => 'Your proof of address is blurred.',
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a clear and readable document, such as a bank statement, utility bill, or affidavit, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 12 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:blurred', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason cropped' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'cropped',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poa_reason   => 'cropped',
            brand        => 'deriv',
            poa_title    => "Your proof of address is cropped or doesn't show complete details.",
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a full document, such as a bank statement, utility bill, or affidavit, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 12 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:cropped', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'reason old' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'old',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poa_reason   => 'old',
            brand        => 'deriv',
            poa_title    => 'Your proof of address is outdated.',
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a clear and readable document, such as a bank statement, utility bill, or affidavit, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 12 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:old', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'unsupported_format' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'unsupported_format',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang       => 'EN',
            loginid    => 'CR10000',
            is_eu      => 0,
            poa_reason => 'unsupported_format',
            brand      => 'deriv',
            poa_title  =>
                'The documents you submitted as proof of address could not be opened as they are either in an unsupported format or are corrupted.',
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a valid document such as a bank statement, utility bill, or affidavit, in JPG, JPEG, PNG, or PDF formats, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 12 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:unsupported_format', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'screenshot' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'screenshot',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poa_reason   => 'screenshot',
            brand        => 'deriv',
            poa_title    => "We don't accept screenshots as proof of address. We also don't accept addresses on envelopes.",
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a valid document, such as a bank statement, utility bill, or affidavit, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 12 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:screenshot', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'envelope' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'envelope',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poa_reason   => 'envelope',
            brand        => 'deriv',
            poa_title    => "We don't accept addresses on envelopes as proof of address. We also don't accept screenshots.",
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a valid document, such as a bank statement, utility bill, or affidavit, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 12 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:envelope', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'different_name' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'different_name',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poa_reason   => 'different_name',
            brand        => 'deriv',
            poa_title    => "The name on the proof of address doesn't match your Deriv profile.",
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a clear and readable document, such as a bank statement, utility bill, or affidavit, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 12 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:different_name', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'capitec_stat_no_match' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'capitec_stat_no_match',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poa_reason   => 'capitec_stat_no_match',
            brand        => 'deriv',
            poa_title    => 'Your proof of address does not meet our verification standards.',
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a signed and stamped bank statement which clearly shows the account number you used to fund your Deriv account.',
                'Or you may submit a different proof of address, such as a utility bill or affidavit, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 12 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:capitec_stat_no_match', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'password_protected' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'password_protected',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poa_reason   => 'password_protected',
            brand        => 'deriv',
            poa_title    => 'The documents you submitted as proof of address are password-protected.',
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please remove password-protection from the documents and resubmit them.',
                'Alternatively, you can submit a different proof of address such as a bank statement, utility bill, or affidavit, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 12 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:password_protected', 'country:COL']},
            },
            'Expected dd metrics';
    };

    subtest 'irrelevant_documents' => sub {
        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'irrelevant_documents',
            'loginid'    => $test_client->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties}, {
            lang         => 'EN',
            loginid      => 'CR10000',
            is_eu        => 0,
            poa_reason   => 'irrelevant_documents',
            brand        => 'deriv',
            poa_title    => 'Your proof of address does not meet our verification standards.',
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a valid document, such as a bank statement, utility bill, or affidavit, with the following requirements'

            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 12 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:irrelevant_documents', 'country:COL']},
            },
            'Expected dd metrics';
    };

};

subtest 'allow resubmission of both poi and poa' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'EN',
        app_id     => $app_id,
    );

    request($req);
    undef @track_args;

    my $param = {
        'poi_reason' => 'blurred',
        'poa_reason' => 'blurred',
        'loginid'    => $test_client->loginid,
    };
    @metrics = ();

    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
    my $result  = $handler->($param)->get;
    ok $result, 'Success result';

    my ($customer, %r_args) = @track_args;

    is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

    cmp_deeply $r_args{properties},
        {
        poa_subtitle => [
            'Please visit your profile to verify/authenticate your account. Submit a clear and readable document, such as a bank statement, utility bill, or affidavit, with the following requirements:'
        ],
        poi_title  => 'Your proof of identity is blurred.',
        title      => 'We couldn\'t verify your account',
        first_name => 'bRaD',
        poa_reason => 'blurred',
        brand      => 'deriv',
        loginid    => 'CR10000',
        poa_layout => [
            'bears your name that matches your Deriv profile',
            'shows a residential address that matches your Deriv profile',
            'is dated within the last 12 months'
        ],
        poi_layout => [
            'bears your name that matches your Deriv profile',
            'shows the date of issue and/or expiry (if applicable)',
            'shows your full date of birth',
            'shows your photo'
        ],
        poa_title    => 'Your proof of address is blurred.',
        lang         => 'EN',
        poi_reason   => 'blurred',
        poi_subtitle => [
            'Please visit your profile to verify/authenticate your account. Submit a high-resolution, clear, and readable document, such as a passport, driving licence, or national identity card, with the following requirements:'
        ],
        is_eu => 0
        },
        'event properties are ok';

    is $r_args{properties}->{loginid}, $test_client->loginid, "got correct customer loginid";

    cmp_deeply + {@metrics},
        +{
        'event.poi.allow_resubmission.reason' => {tags => ['reason:blurred', 'country:COL']},
        'event.poa.allow_resubmission.reason' => {tags => ['reason:blurred', 'country:COL']}
        },
        'Expected dd metrics';
};

subtest 'different Broker code' => sub {

    subtest 'MF account' => sub {
        my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        $test_client_mf->residence('es');
        $test_client_mf->save();

        my $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'EN',
            app_id     => $app_id,
        );

        request($req);
        undef @track_args;

        my $param = {
            'poa_reason' => 'old',
            'loginid'    => $test_client_mf->loginid,
        };
        @metrics = ();

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{notify_resubmission_of_poi_poa_documents};
        my $result  = $handler->($param)->get;
        ok $result, 'Success result';

        my ($customer, %r_args) = @track_args;

        is $r_args{event}, 'poi_poa_resubmission', "Event=notify_resubmission_of_poi_poa_documents";

        cmp_deeply $r_args{properties},
            {
            lang         => 'EN',
            loginid      => 'MF90000000',
            is_eu        => 1,
            poa_reason   => 'old',
            brand        => 'deriv',
            poa_title    => 'Your proof of address is outdated.',
            first_name   => 'bRaD',
            poa_subtitle => [
                'Please visit your profile to verify/authenticate your account. Submit a clear and readable document, such as a bank statement, utility bill, or affidavit, with the following requirements:'
            ],
            title      => "We couldn't verify your account",
            poa_layout => [
                'bears your name that matches your Deriv profile',
                'shows a residential address that matches your Deriv profile',
                'is dated within the last 6 months'
            ]
            },
            'event properties are ok';

        is $r_args{properties}->{loginid}, $test_client_mf->loginid, "got correct customer loginid";

        cmp_deeply + {@metrics},
            +{
            'event.poa.allow_resubmission.reason' => {tags => ['reason:old', 'country:ESP']},
            },
            'Expected dd metrics';
    };

};

done_testing();
