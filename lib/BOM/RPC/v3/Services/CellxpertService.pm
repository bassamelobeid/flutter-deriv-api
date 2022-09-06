package BOM::RPC::v3::Services::CellxpertService;

=head1 NAME

BOM::RPC::v3::Services::CellxpertService - helpers for CellxpertService

=head1 DESCRIPTION

This module contains the helpers for dealing with CellXpert API service.

=cut

use strict;
use warnings;

use BOM::Config;
use WebService::Async::Cellxpert;
use Syntax::Keyword::Try;
use Log::Any qw( $log );
use IO::Async::Loop;
use BOM::RPC::v3::Utility;
use BOM::RPC::Transport::HTTP;

my $loop;
my $cx;
my $cx_config;

BEGIN {
    $cx_config = BOM::Config::third_party()->{cellxperts};
    $cx        = WebService::Async::Cellxpert->new(base_uri => $cx_config->{base_uri});
    $loop      = IO::Async::Loop->new;
    $loop->add($cx);
}

=head2 verify_email

Verify Email from RPC and returns {status=>1} if email is not alreayd exist else returns CXUsernameExists

=over 4

=item * C<username> - C<Str> The username to check (that in our system it is equal to email)

=item * C<verification> - verification object to create data for email template

=item * C<existing_user> - if user exists in our DB then this field contains L<BOM::Client::User> object otherwise it is null

=back

=cut

sub verify_email {
    my ($username, $verification, $existing_user, $language) = @_;
    try {
        if ($existing_user) {
            my $data = $verification->{account_opening_existing}->();
            BOM::Platform::Event::Emitter::emit(
                'account_opening_existing',
                {
                    loginid    => $existing_user->get_default_client->loginid,
                    properties => {
                        code               => $data->{template_args}->{code} // '',
                        language           => $language,
                        login_url          => $data->{template_args}->{login_url}          // '',
                        password_reset_url => $data->{template_args}->{password_reset_url} // '',
                        live_chat_url      => $data->{template_args}->{live_chat_url}      // '',
                        verification_url   => $data->{template_args}->{verification_url}   // '',
                        email              => $data->{template_args}->{email}              // '',
                    },
                });
        } else {
            my $is_username_available = $cx->is_username_available($username)->get;
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'CXUsernameExists',
                    message_to_client => 'A user with this email already exists'
                }) unless $is_username_available;

            my $data = $verification->{account_opening_new}->();
            BOM::Platform::Event::Emitter::emit(
                'account_opening_new',
                {
                    verification_url => $data->{template_args}->{verification_url} // '',
                    code             => $data->{template_args}->{code}             // '',
                    email            => $username,
                    live_chat_url    => $data->{template_args}->{live_chat_url} // '',
                });
        }
        return;
    } catch ($e) {
        $log->error("Error in verify_email CellxpertService.pm: $e");
        return BOM::RPC::v3::Utility::create_error({
            code              => 'CXRuntimeError',
            message_to_client => 'Could not register user'
        });
    }
}

=head2 affiliate_account_add

Register the affiliate to through the CellXpert API with corresponding inputs

=over 4

=item * C<email> - C<Str> The email that entered in previous step of registration

=item * C<first_name> - C<Str> The firstname

=item * C<last_name> - C<Str> The last_name

=item * C<non_pep_declaration> - C<Bool> declare that I am not a politically exposed person.

=item * C<tnc_accepted> - C<Bool> The terms and conditions boolean field

=item * C<password> - C<Str> The password


=back

=cut

sub affiliate_account_add {
    my ($email, $first_name, $last_name, $non_pep_declaration, $tnc_accepted, $password) = @_;
    try {
        my $aff_id = $cx->register_affiliate(
            Username                   => $email,
            Password                   => $password,
            Firstname                  => $first_name,
            LastName                   => $last_name,
            Email                      => $email,
            AgreedToTermsAndConditions => $tnc_accepted,
            AgreedToPrivacyPolicy      => $non_pep_declaration,
        )->get;
        return {
            code         => "SuccessRegister",
            affiliate_id => int($aff_id)};
    } catch ($e) {
        if ($e =~ m/already exist/) {
            return {
                code => "AlreadyRegistered",
            };
        }
        return {
            code              => "CXRuntimeError",
            message_to_client => $e
        };
    }
}

END {
    $loop->remove($cx);
}

1;
