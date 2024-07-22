use strict;
use warnings;

use Future;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use Test::Fatal;
use Test::Deep;
use Guard;
use Log::Any::Test;
use Log::Any                                   qw($log);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::User;
use BOM::Event::Process;
use JSON::MaybeUTF8        qw(decode_json_utf8);
use BOM::Platform::Context qw(request);
use BOM::Event::Actions::Client;

my $service_contexts = BOM::Test::Customer::get_service_contexts();

subtest '[Payops] Update account status' => sub {
    # Setup 3 accounts
    my $customer = BOM::Test::Customer->create(
        place_of_birth => 'co',
        email_verified => 1,
        date_joined    => Date::Utility->new()->_minus_years(10)->datetime_yyyymmdd_hhmmss,
        clients        => [{
                name            => 'CR',
                broker_code     => 'CR',
                default_account => 'USD',
            },
            {
                name            => 'CR_SIBLING',
                broker_code     => 'CR',
                default_account => 'LTC',
            },
            {
                name        => 'VRTC',
                broker_code => 'VRTC',
            }]);
    my $client       = $customer->get_client_object('CR');
    my $test_sibling = $customer->get_client_object('CR_SIBLING');
    my $test_virtual = $customer->get_client_object('VRTC');

    my @statuses = qw/
        age_verification  cashier_locked  unwelcome  withdrawal_locked
        mt5_withdrawal_locked  ukgc_funds_protection  financial_risk_approval
        crs_tin_information  max_turnover_limit_not_set
        professional_requested  professional  professional_rejected  tnc_approval
        migrated_single_email
        require3ds  skip_3ds  ok  ico_only  allowed_other_card  can_authenticate
        social_signup  trusted  pa_withdrawal_explicitly_allowed  financial_assessment_required
        address_verified  no_withdrawal_or_trading no_trading  allow_document_upload internal_client
        closed  transfers_blocked  shared_payment_method  personal_details_locked
        allow_poi_resubmission  allow_poa_resubmission migrated_universal_password
        poi_name_mismatch crypto_auto_reject_disabled crypto_auto_approve_disabled potential_fraud
        deposit_attempt df_deposit_requires_poi smarty_streets_validated trading_hub poi_dob_mismatch
        allow_poinc_resubmission cooling_off_period poi_poa_uploaded
        /;
    my @self_propagated_statuses = qw/
        smarty_streets_validated allow_document_upload address_verified age_verification
        migrated_single_email require3ds allowed_other_card ico_only can_authenticate
        /;

    for my $status (@statuses) {
        my $args = {
            status  => $status,
            loginid => $customer->get_client_loginid('CR'),
            reason  => 'Attempted to deposit into account using more than one credit card'
        };

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{payops_event_update_account_status};
        $handler->($args, $service_contexts);

        delete $client->{status};    #clear status cache
                                     # check the results
        ok $client->status->$status, "The $status status is set on the client";
        is $client->status->$status->{reason}, 'Attempted to deposit into account using more than one credit card', "Correct reason for $status";

        delete $client->{status};    #clear status cache
                                     # ensure we dont override the existing result
        $client->status->$status->{reason} = 'Old reason';
        $handler->($args, $service_contexts);
        is $client->status->$status->{reason}, 'Old reason', "Status reason was not changed for $status";

        delete $client->{status};    #clear status cache
                                     # ensure we can clear it
        $args->{clear} = 1;
        $handler->($args, $service_contexts);
        is $client->status->$status, undef, "The $status status is clear on the client";

        # Exclude those self propagated statuses
        next if grep { $_ eq $status } @self_propagated_statuses;

        # Do the similar but on bring the sibilings along :-)
        $args->{set} = 'real';
        delete $args->{clear};
        $handler->($args, $service_contexts);
        # Target itself
        delete $client->{status};          #clear status cache
                                           # check the results
        ok $client->status->$status, "The $status status is set on the client";
        is $client->status->$status->{reason}, 'Attempted to deposit into account using more than one credit card', "Correct reason for $status";
        # Real siblings
        delete $test_sibling->{status};    #clear status cache
                                           # check the results
        ok $test_sibling->status->$status, "The $status status is set on the sibling";
        is $test_sibling->status->$status->{reason}, 'Attempted to deposit into account using more than one credit card',
            "Correct reason for $status";
        # Try to clear it
        $args->{clear} = 'real';
        delete $args->{set};
        $handler->($args, $service_contexts);
        # Target itself
        delete $client->{status};          #clear status cache
                                           # check the results
        is $client->status->$status, undef, "The $status status is cleared on the client";
        # Real siblings
        delete $test_sibling->{status};    #clear status cache
                                           # check the results
        is $test_sibling->status->$status, undef, "The $status status is cleared on the sibling";

        # Do the similar but on bring the ALL sibilings along :evil:
        $args->{set} = 'all';
        delete $args->{clear};
        $handler->($args, $service_contexts);
        # Target itself
        delete $client->{status};          #clear status cache
                                           # check the results
        ok $client->status->$status, "The $status status is set on the client";
        is $client->status->$status->{reason}, 'Attempted to deposit into account using more than one credit card', "Correct reason for $status";
        # Real siblings
        delete $test_sibling->{status};    #clear status cache
                                           # check the results
        ok $test_sibling->status->$status, "The $status status is set on the sibling";
        is $test_sibling->status->$status->{reason}, 'Attempted to deposit into account using more than one credit card',
            "Correct reason for $status";
        # Virtual siblings
        delete $test_virtual->{status};    #clear status cache
                                           # check the results
        ok $test_virtual->status->$status, "The $status status is set on the virtual account";
        is $test_virtual->status->$status->{reason}, 'Attempted to deposit into account using more than one credit card',
            "Correct reason for $status";
        # Try to clear it
        $args->{clear} = 'all';
        delete $args->{set};
        $handler->($args, $service_contexts);
        # Target itself
        delete $client->{status};          #clear status cache
                                           # check the results
        is $client->status->$status, undef, "The $status status is cleared on the client";
        # Real siblings
        delete $test_sibling->{status};    #clear status cache
                                           # check the results
        is $test_sibling->status->$status, undef, "The $status status is cleared on the sibling";
        # Virtual siblings
        delete $test_virtual->{status};    #clear status cache
                                           # check the results
        is $test_virtual->status->$status, undef, "The $status status is cleared on the virtual sibling";
    }
};

subtest '[Payops] Request POO' => sub {
    my $customer = BOM::Test::Customer->create(
        first_name => 'ABCD',
        clients    => [{
                name        => 'CR',
                broker_code => 'CR'
            }]);

    my $client = $customer->get_client_object('CR');

    my $args = {
        loginid                  => $client->loginid,
        trace_id                 => 1,
        payment_service_provider => 'VISA'
    };
    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{payops_event_request_poo};
    $handler->($args, $service_contexts);
    my $poo_list = $client->proof_of_ownership->list();
    my $found    = 0;
    $found = scalar grep { $_->{trace_id} == 1 } $poo_list->@*;
    ok $found, "The POO request is added into the clientdb";
};

subtest 'payops event email' => sub {
    my $handler    = BOM::Event::Process->new(category => 'track')->actions->{payops_event_email};
    my $track_mock = Test::MockModule->new('BOM::Event::Services::Track');
    my $track_properties;

    $track_mock->mock(
        'track_event',
        sub {
            $track_properties = +{@_};
            delete $track_properties->{service_contexts};
            return Future->done;
        });

    my $customer = BOM::Test::Customer->create(
        residence      => 'id',
        email_verified => 1,
        email_consent  => 1,
        clients        => [{
                name        => 'CR',
                broker_code => 'CR'
            },
        ]);

    $track_properties = undef;

    $handler->({
            event_name => 'payops_event_email',
            subject    => 'testing with client login id',
            loginid    => $customer->get_client_loginid('CR'),
            template   => 'test',
            contents   => 'Testing CR',
            properties => {
                test => 1,
                abc  => 'abc',
            },
        },
        $service_contexts
    )->get;

    cmp_deeply $track_properties,
        +{
        event      => 'payops_event_email',
        properties => {
            email          => $customer->get_email(),
            phone          => '+15417543010',
            email_template => 'test',
            subject        => 'testing with client login id',
            contents       => 'Testing CR',
            country        => 'id',
            language       => 'en',
            test           => '1',
            abc            => 'abc',
            email_consent  => 1
        },
        loginid => $customer->get_client_loginid('CR'),
        },
        'Expected track event triggered';
};

subtest 'onfido context unit testing' => sub {
    my $redis_events = BOM::Config::Redis::redis_events_write();
    my $key          = +BOM::Event::Actions::Client::ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY;

    my $applicant_id = 'test';
    my $request      = request();

    my $context = {
        brand_name => $request->brand->name,
        language   => $request->language,
        app_id     => $request->app_id,
    };

    subtest '_save_request_context' => sub {
        BOM::Event::Actions::Client::_save_request_context($applicant_id)->get;

        my $request = request();

        cmp_deeply decode_json_utf8($redis_events->get($key . $applicant_id)), $context, 'Expected context from events redis';
    };

    subtest '_clear_cached_context' => sub {
        BOM::Event::Actions::Client::_clear_cached_context($applicant_id)->get;

        is $redis_events->get($key . $applicant_id), undef, 'Context cleared from events redis';
    };

    subtest '_restore_request' => sub {
        BOM::Event::Actions::Client::_restore_request($applicant_id, [qw/brand:test/])->get;

        my $req2 = request();

        is $req2->brand_name, 'test', 'recovered brand test from tags';

        BOM::Event::Actions::Client::_restore_request($applicant_id)->get;

        $req2 = request();

        is $req2->brand_name, 'test', 'recovered brand test from current request';

        my $new_req = BOM::Platform::Context::Request->new(brand_name => 'deriv');
        request($new_req);

        BOM::Event::Actions::Client::_restore_request($applicant_id)->get;

        $req2 = request();

        is $req2->brand_name, 'deriv', 'recovered brand deriv from current request';

        subtest 'restore from events redis' => sub {
            my $new_req = BOM::Platform::Context::Request->new(brand_name => 'binary');
            request($new_req);

            BOM::Event::Actions::Client::_save_request_context($applicant_id)->get;

            BOM::Event::Actions::Client::_restore_request($applicant_id)->get;

            my $req2 = request();

            is $req2->brand_name, 'binary', 'Expected brand';
        };
    };
};

done_testing();
