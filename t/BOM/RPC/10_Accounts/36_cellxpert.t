use strict;
use warnings;

use Test::MockModule;
use Test::More;
use BOM::RPC::v3::Services::CellxpertService;
use BOM::RPC::v3::EmailVerification qw(email_verification);
use Future;

subtest 'partner_account_opening test' => sub {
    subtest 'username_available_with_valid_email' => sub {
        my $verification = email_verification({
            code             => "test_code",
            website_name     => "deriv.com",
            verification_uri => "http://verification_uri",
            language         => "EN",
            email            => "some_username",
        });

        my $mocked_cellxpert_service = Test::MockModule->new('WebService::Async::Cellxpert');
        $mocked_cellxpert_service->redefine(
            'is_username_available',
            sub {
                my $username = shift;
                return Future->done("$username is available");
            });

        my $mocked_event_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
        $mocked_event_emitter->redefine(
            'emit',
            sub {
                my ($type, $args) = @_;
                warn "Type is incorrect" unless ($type eq "account_opening_new");
                warn "Verification URL is incorrect"
                    unless ($args->{verification_url} eq "http://verification_uri?action=signup&lang=EN&code=test_code");
                warn "Code is incorrect"  unless ($args->{code} eq "test_code");
                warn "Email is incorrect" unless ($args->{email} eq "some_username");
            });
        my $existing_user = BOM::User->new(
            email => 'test@email.com',
        );
        my $response = BOM::RPC::v3::Services::CellxpertService::verify_email("some_username", $verification, $existing_user);
        is $response, undef;

        $response = BOM::RPC::v3::Services::CellxpertService::verify_email("some_username", $verification, 0);
        is $response, undef;

        $mocked_event_emitter->unmock_all();
        $mocked_cellxpert_service->unmock_all();
    };

};

subtest 'affiliate_account_add test' => sub {
    my $mocked_cellxpert_service = Test::MockModule->new('WebService::Async::Cellxpert');

    subtest 'register_affiliate successfull' => sub {
        $mocked_cellxpert_service->redefine(
            'register_affiliate',
            sub {
                my $username = shift;
                return Future->done("12345678");
            });

        my $response = BOM::RPC::v3::Services::CellxpertService::affiliate_account_add("some_username", "first_name", "last_name", 1, 1, "password");
        is $response->{affiliate_id}, 12345678;

        $mocked_cellxpert_service->unmock_all();

    };

    subtest 'register_affiliate unsuccessful' => sub {
        $mocked_cellxpert_service->redefine(
            'register_affiliate',
            sub {
                my $username = shift;
                return Future->fail();
            });

        my $response = BOM::RPC::v3::Services::CellxpertService::affiliate_account_add("some_username", "first_name", "last_name", 1, 1, "password");
        is $response->{error}->{code}, "CXRuntimeError";

        $mocked_cellxpert_service->unmock_all();

    };

};

done_testing();
