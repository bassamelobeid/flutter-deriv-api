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
use BOM::User;
use BOM::Event::Process;

subtest '[Payops] Update account status' => sub {
    # Setup 3 accounts
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'abcd1234@example.com',
        first_name  => 'ABCD'
    });
    $client->set_default_account('USD');

    my $test_sibling = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $test_sibling->set_default_account('LTC');

    my $test_virtual = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $client->email
    });

    my $test_user = BOM::User->create(
        email          => $client->email,
        password       => "hello",
        email_verified => 1,
    );
    $test_user->add_client($client);
    $test_user->add_client($test_sibling);
    $test_user->add_client($test_virtual);
    $client->place_of_birth('co');
    $client->binary_user_id($test_user->id);
    $client->save;
    $test_sibling->binary_user_id($test_user->id);
    $test_sibling->save;
    $test_virtual->binary_user_id($test_user->id);
    $test_virtual->save;

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
            loginid => $client->loginid,
            reason  => 'Attempted to deposit into account using more than one credit card'
        };

        my $handler = BOM::Event::Process->new(category => 'generic')->actions->{payops_event_update_account_status};
        $handler->($args);

        delete $client->{status};    #clear status cache
                                     # check the results
        ok $client->status->$status, "The $status status is set on the client";
        is $client->status->$status->{reason}, 'Attempted to deposit into account using more than one credit card', "Correct reason for $status";

        delete $client->{status};    #clear status cache
                                     # ensure we dont override the existing result
        $client->status->$status->{reason} = 'Old reason';
        $handler->($args);
        is $client->status->$status->{reason}, 'Old reason', "Status reason was not changed for $status";

        delete $client->{status};    #clear status cache
                                     # ensure we can clear it
        $args->{clear} = 1;
        $handler->($args);
        is $client->status->$status, undef, "The $status status is clear on the client";

        # Exclude those self propagated statuses
        next if grep { $_ eq $status } @self_propagated_statuses;

        # Do the similar but on bring the sibilings along :-)
        $args->{set} = 'real';
        delete $args->{clear};
        $handler->($args);
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
        $handler->($args);
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
        $handler->($args);
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
        $handler->($args);
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
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'abcd1234@example.com',
        first_name  => 'ABCD'
    });

    my $args = {
        loginid                  => $client->loginid,
        trace_id                 => 1,
        payment_service_provider => 'VISA'
    };
    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{payops_event_request_poo};
    $handler->($args);
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

            return Future->done;
        });

    ## Test client loginid

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $user = BOM::User->create(
        email         => 'unit_test@binary.com',
        password      => 'secret',
        email_consent => 1,
    );

    $user->add_client($client);
    $client->binary_user_id($user->id);
    $client->user($user);
    $client->save;

    $track_properties = undef;

    $handler->({
            event_name => 'payops_event_email',
            subject    => 'testing with client login id',
            loginid    => $client->loginid,
            template   => 'test',
            contents   => 'Testing CR',
            properties => {
                test => 1,
                abc  => 'abc',
            },
        })->get;

    cmp_deeply $track_properties,
        +{
        event      => 'payops_event_email',
        properties => {
            email          => 'unit_test@binary.com',
            phone          => '+15417543010',
            email_template => 'test',
            subject        => 'testing with client login id',
            contents       => 'Testing CR',
            country        => 'id',
            language       => 'EN',
            test           => '1',
            abc            => 'abc',
            email_consent  => 1
        },
        loginid => $client->loginid,
        },
        'Expected track event triggered';

};

done_testing();
