package BOM::RPC::v3::VerifyEmail::Functions;

=head1 NAME

BOM::RPC::v3::VerifyEmail::Functions - Functions needed for verify_email rpc endpoint

=head1 DESCRIPTION

This module contains all functions needed for verify_email rpc calls

=cut

use strict;
use warnings;
use BOM::Platform::Event::Emitter;
use Log::Any qw($log);
use Email::Valid;
use Syntax::Keyword::Try;
use BOM::RPC::v3::Utility;
use BOM::Rules::Engine;
use BOM::Database::Model::OAuth;
use BOM::Platform::Context qw (localize request);
use BOM::User::Client;
use BOM::RPC::v3::EmailVerification qw(email_verification);

use constant {REQUEST_EMAIL_TOKEN_TTL => 3600};

=head2 new

Constructor of Verify Email Functions

=over 4

Returns Functions object

=back

=cut

sub new {
    my ($class, %params) = @_;

    $params{utm_medium}   = $params{url_parameters}->{utm_medium}   // '';
    $params{utm_campaign} = $params{url_parameters}->{utm_campaign} // '';
    $params{email}        = lc $params{args}->{verify_email};
    $params{type}         = $params{args}->{type};
    $params{url_params}   = $params{args}->{url_parameters};

    my $self = \%params;
    bless $self, $class;

    return $self;

}

=head2 create_token

Create new token based on email and type of verify_email RPC call

=over 4

=back

=cut

sub create_token {
    my ($self) = @_;
    $self->{code} = BOM::Platform::Token->new({
            email       => $self->{email},
            expires_in  => REQUEST_EMAIL_TOKEN_TTL,
            created_for => $self->{type},
        })->token;
    return;
}

=head2 is_existing_user_closed

Return existing_user if it is not closed yet

=over 4

=back

=cut

sub is_existing_user_closed {
    my ($self) = @_;
    return ($self->{existing_user} and $self->{existing_user}->is_closed);
}

=head2 send_close_account_email

Send close_account verify_email for two different cases: account_opening, reset_password

=over 4

=back

=cut

sub send_close_account_email {
    my ($self)         = @_;
    my $data           = $self->{email_verification}->{closed_account}->();
    my %possible_types = (
        account_opening => "verify_email_closed_account_account_opening",
        reset_password  => "verify_email_closed_account_reset_password"
    );
    BOM::Platform::Event::Emitter::emit(
        $possible_types{$self->{type}} // "verify_email_closed_account_other",
        {
            loginid    => ($self->{existing_user}->bom_loginids)[0],
            properties => {
                language      => $self->{language},
                type          => $data->{template_args}->{type}          // '',
                live_chat_url => $data->{template_args}->{live_chat_url} // '',
                email         => $data->{template_args}->{email}         // '',
            }});
    return {status => 1};
}

=head2 create_loginid

Set loginid from token_details if there are any

=over 4

=back

=cut

sub create_loginid {
    my ($self) = @_;
    $self->{loginid} = $self->{token_details} ? $self->{token_details}->{loginid} : undef;
    return;
}

=head2 create_client

Create BOM::User::Client and check the email should same as user already exists in DB

=over 4

=back

=cut

sub create_client {
    my ($self) = @_;
    # If user is logged in, email for verification must belong to the logged in account
    if ($self->{loginid}) {
        $self->{client} = BOM::User::Client->new({
            loginid      => $self->{loginid},
            db_operation => 'replica'
        });
        return {status => 1} if $self->{client}->email ne $self->{email};
    }
    return "OK";
}

=head2 create_email_verification_function

Create Email verification function base on verify_email arguments

=over 4

=back

=cut

sub create_email_verification_function {
    my ($self) = @_;
    $self->{email_verification} = email_verification({
        code             => $self->{code},
        website_name     => $self->{website_name},
        verification_uri => BOM::RPC::v3::Utility::get_verification_uri($self->{source}),
        language         => $self->{language},
        source           => $self->{source},
        app_name         => BOM::RPC::v3::Utility::get_app_name($self->{source}),
        email            => $self->{email},
        type             => $self->{type},
        $self->{url_params} ? ($self->{url_params}->%*) : (),
    });
    return;
}

=head2 create_existing_user

Create existing_user

=over 4

=back

=cut

sub create_existing_user {
    my ($self) = @_;
    $self->{existing_user} = BOM::User->new(
        email => $self->{email},
    );
}

=head2 reset_password

If $self->type is `reset_password` then this function will execute

=over 4

=back

=cut

sub reset_password {
    my ($self) = @_;
    if ($self->{existing_user}) {
        my $data = $self->{email_verification}->{reset_password}->();
        BOM::Platform::Event::Emitter::emit(
            'reset_password_request',
            {
                loginid    => $self->{existing_user}->get_default_client->loginid,
                properties => {
                    verification_url => $data->{template_args}->{verification_url}  // '',
                    social_login     => $data->{template_args}->{has_social_signup} // '',
                    first_name       => $self->{existing_user}->get_default_client->first_name,
                    code             => $data->{template_args}->{code} // '',
                    email            => $self->{email},
                },
            });
    }
    return;

}

=head2 request_email

If $self->type is `request_email` then this function will execute

=over 4

=back

=cut

sub request_email {
    my ($self) = @_;
    if ($self->{existing_user}) {
        my $data              = $self->{email_verification}->{request_email}->();
        my $has_social_signup = $data->{template_args}->{has_social_signup} ? 1 : 0;

        BOM::Platform::Event::Emitter::emit(
            'request_change_email',
            {
                loginid    => $self->{existing_user}->get_default_client->loginid,
                properties => {
                    verification_uri      => $data->{template_args}->{verification_url} // '',
                    first_name            => $self->{existing_user}->get_default_client->first_name,
                    code                  => $data->{template_args}->{code} // '',
                    email                 => $self->{email},
                    time_to_expire_in_min => REQUEST_EMAIL_TOKEN_TTL / 60,
                    language              => $self->{language},
                    social_signup         => $has_social_signup,
                    live_chat_url         => request()->brand->live_chat_url
                },
            });
    }
    return;
}

=head2 account_opening

If $self->type is `account_opening` then this function will execute for this cases:
- affiliate
- normal account

=over 4

=back

=cut

sub account_opening {
    my ($self) = @_;
    if ($self->{utm_medium} eq 'affiliate' and $self->{utm_campaign} eq 'MyAffiliates' and $self->{url_params}->{affiliate_token}) {
        my $aff                  = BOM::MyAffiliates->new();
        my $myaffiliate_email    = '';
        my $received_aff_details = $aff->get_affiliate_details($self->{url_params}->{affiliate_token});
        if ($received_aff_details and $received_aff_details->{TOKEN}->{USER_ID} !~ m/Error/) {
            $myaffiliate_email = $received_aff_details->{TOKEN}->{USER}->{EMAIL} // '';
        } else {
            $log->warnf("Could not fetch affiliate details from MyAffiliates. Please check credentials: %s", $aff->errstr);
        }

        if ($myaffiliate_email eq $self->{email}) {
            my $data = $self->{email_verification}->{self_tagging_affiliates}->();
            BOM::Platform::Event::Emitter::emit(
                'self_tagging_affiliates',
                {
                    properties => {
                        live_chat_url => $data->{template_args}->{live_chat_url} // '',
                        email         => $data->{template_args}->{email}         // '',
                    },
                });
        } else {
            unless ($self->{existing_user}) {
                my $data = $self->{email_verification}->{account_opening_new}->();
                BOM::Platform::Event::Emitter::emit(
                    'account_opening_new',
                    {
                        verification_url => $data->{template_args}->{verification_url} // '',
                        code             => $data->{template_args}->{code}             // '',
                        email            => $self->{email},
                        live_chat_url    => $data->{template_args}->{live_chat_url} // '',
                    });
            } else {
                my $data = $self->{email_verification}->{account_opening_existing}->();
                BOM::Platform::Event::Emitter::emit(
                    'account_opening_existing',
                    {
                        loginid    => $self->{existing_user}->get_default_client->loginid,
                        properties => {
                            code               => $data->{template_args}->{code} // '',
                            language           => $self->{params}->{language},
                            login_url          => $data->{template_args}->{login_url}          // '',
                            password_reset_url => $data->{template_args}->{password_reset_url} // '',
                            live_chat_url      => $data->{template_args}->{live_chat_url}      // '',
                            verification_url   => $data->{template_args}->{verification_url}   // '',
                            email              => $data->{template_args}->{email}              // '',
                        },
                    });
            }
        }
    } else {
        unless ($self->{existing_user}) {
            my $data = $self->{email_verification}->{account_opening_new}->();
            BOM::Platform::Event::Emitter::emit(
                'account_opening_new',
                {
                    verification_url => $data->{template_args}->{verification_url} // '',
                    code             => $data->{template_args}->{code}             // '',
                    email            => $self->{email},
                    live_chat_url    => $data->{template_args}->{live_chat_url} // '',
                });

        } else {
            my $data = $self->{email_verification}->{account_opening_existing}->();
            BOM::Platform::Event::Emitter::emit(
                'account_opening_existing',
                {
                    loginid    => $self->{existing_user}->get_default_client->loginid,
                    properties => {
                        code               => $data->{template_args}->{code} // '',
                        language           => $self->{params}->{language},
                        login_url          => $data->{template_args}->{login_url}          // '',
                        password_reset_url => $data->{template_args}->{password_reset_url} // '',
                        live_chat_url      => $data->{template_args}->{live_chat_url}      // '',
                        verification_url   => $data->{template_args}->{verification_url}   // '',
                        email              => $data->{template_args}->{email}              // '',
                    },
                });
        }
    }
    return;
}

=head2 partner_account_opening

If $self->type is `partner_account_opening` then this function will execute

This is related to CellXpert API (Thirdparty replacement for myaffiliate) registration and 
will call CX service to handle registration

=over 4

=back

=cut

sub partner_account_opening {
    my ($self) = @_;
    return BOM::RPC::v3::Services::CellxpertService::verify_email($self->{email}, $self->{email_verification}, $self->{existing_user},
        $self->{language});
}

=head2 common_payment_withdraw

helper function for same actions in both `payment_withdraw` and `paymentagent_withdraw`

=over 4

=back

=cut

sub common_payment_withdraw {
    my ($self) = @_;
    # TODO: the following should be replaced by $rule_engine->validate_action($self->{type} )
    # We should just wait until rhe rule engine integration of PA-withdrawal and cashier withdrawal actions.
    my $validation_error = BOM::RPC::v3::Utility::cashier_validation($self->{client}, $self->{type});
    return $validation_error if $validation_error;
    if (BOM::RPC::v3::Utility::is_impersonating_client($self->{token})) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'Permission Denied',
                message_to_client => localize('You can not perform a withdrawal while impersonating an account')});
    }
    my $data = $self->{email_verification}->{payment_withdraw}->();
    BOM::Platform::Event::Emitter::emit(
        'request_payment_withdraw',
        {
            loginid    => $self->{client}->loginid,
            properties => {
                verification_url => $data->{template_args}->{verification_url} // '',
                live_chat_url    => $data->{template_args}->{live_chat_url}    // '',
                first_name       => $self->{client}->first_name,
                code             => $data->{template_args}->{code} // '',
                email            => $self->{email},
                language         => $self->{params}->{language},
            },
        });
    return "OK";
}

=head2 payment_withdraw

If $self->type is `payment_withdraw` then this function will execute

=over 4

=back

=cut

sub payment_withdraw {
    my ($self) = @_;
    if ($self->{client}) {
        my $result = common_payment_withdraw($self);
        return $result unless $result eq 'OK';
    }
    return;
}

=head2 paymentagent_withdraw

If $self->type is `paymentagent_withdraw` then this function will execute

=over 4

=back

=cut

sub paymentagent_withdraw {
    my ($self) = @_;
    if ($self->{client}) {

        my $rule_engine = BOM::Rules::Engine->new(client => $self->{client});
        try {
            $rule_engine->apply_rules(
                [qw/client.is_not_virtual paymentagent.paymentagent_withdrawal_allowed/],
                loginid                    => $self->{client}->loginid,
                source_bypass_verification => 0,
            );
        } catch ($rules_error) {
            return BOM::RPC::v3::Utility::rule_engine_error($rules_error);
        }

        my $result = common_payment_withdraw($self);
        return $result unless $result eq 'OK';

    }
    return;
}

=head2 trading_platform_mt5_password_reset

If $self->type is `trading_platform_mt5_password_reset` then this function will execute.
This function will reset password for trading_platform_mt5 if user exists with sending event to bom-event

=over 4

=back

=cut

sub trading_platform_mt5_password_reset {
    my ($self) = @_;
    if ($self->{existing_user}) {
        my $verification_function = $self->{email_verification}->{trading_platform_mt5_password_reset}->();
        BOM::RPC::v3::Utility::request_email($self->{email}, $verification_function);
        BOM::Platform::Event::Emitter::emit(
            'trading_platform_password_reset_request',
            {
                loginid    => $self->{existing_user}->get_default_client->loginid,
                properties => {
                    first_name       => $self->{existing_user}->get_default_client->first_name,
                    verification_url => $verification_function->{template_args}{verification_url},
                    code             => $verification_function->{template_args}{code},
                    platform         => 'mt5',
                },
            });
    }
    return;
}

=head2 trading_platform_dxtrade_password_reset

If $self->type is `trading_platform_dxtrade_password_reset` then this function will execute.
This function will reset password for trading_platform_dxtrade if user exists with sending event to bom-event

=over 4

=back

=cut

sub trading_platform_dxtrade_password_reset {
    my ($self) = @_;
    if ($self->{existing_user}) {
        my $verification_function = $self->{email_verification}->{trading_platform_dxtrade_password_reset}->();
        BOM::RPC::v3::Utility::request_email($self->{email}, $verification_function);

        BOM::Platform::Event::Emitter::emit(
            'trading_platform_password_reset_request',
            {
                loginid    => $self->{existing_user}->get_default_client->loginid,
                properties => {
                    first_name       => $self->{existing_user}->get_default_client->first_name,
                    verification_url => $verification_function->{template_args}{verification_url},
                    code             => $verification_function->{template_args}{code},
                    platform         => 'dxtrade',
                },
            });
    }
    return;
}

=head2 trading_platform_investor_password_reset

If $self->type is `trading_platform_investor_password_reset` then this function will execute.
This function will reset password for trading_platform_investor if user exists with sending event to bom-event

=over 4

=back

=cut

sub trading_platform_investor_password_reset {
    my ($self) = @_;
    if ($self->{existing_user}) {
        my $verification_function = $self->{email_verification}->{trading_platform_investor_password_reset}->();
        BOM::RPC::v3::Utility::request_email($self->{email}, $verification_function);

        BOM::Platform::Event::Emitter::emit(
            'trading_platform_investor_password_reset_request',
            {
                loginid    => $self->{existing_user}->get_default_client->loginid,
                properties => {
                    first_name       => $self->{existing_user}->get_default_client->first_name,
                    verification_url => $verification_function->{template_args}{verification_url},
                    code             => $verification_function->{template_args}{code},
                },
            });
    }
    return;
}

=head2 do_verification

This is main method of VerifyEmail that should call after new.
this will do all input validations and call the related function.

=over 4

=back

=cut

sub do_verification {
    my ($self) = @_;
    return BOM::RPC::v3::Utility::invalid_email() unless Email::Valid->address($self->{email});

    my $error = BOM::RPC::v3::Utility::invalid_params($self->{args});
    return $error if $error;

    $self->create_token();
    $self->create_email_verification_function();
    $self->create_existing_user();

    return $self->send_close_account_email() if $self->is_existing_user_closed();

    $self->create_loginid();

    my $response = $self->create_client();
    return $response unless $response eq "OK";

    my $type = $self->{type};

    die "unknown type $type" unless $self->can($type);
    my $error_response = $self->$type;
    return $error_response if ref $error_response eq 'HASH';

    return {status => 1};
}

1;
