package BOM::RPC;

use strict;
use warnings;
no indirect;

use List::Util qw(any);
use Scalar::Util q(blessed);
use Syntax::Keyword::Try;
use Time::HiRes qw();

use BOM::Config::Runtime;
use BOM::Database::Rose::DB;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Context::Request;
use BOM::RPC::Registry;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::App;
use BOM::RPC::v3::Authorize;
use BOM::RPC::v3::Cashier;
use BOM::RPC::v3::Contract;
use BOM::RPC::v3::CopyTrading;
use BOM::RPC::v3::CopyTrading::Statistics;
use BOM::RPC::v3::DocumentUpload;
use BOM::RPC::v3::MarketData;
use BOM::RPC::v3::MarketDiscovery;
use BOM::RPC::v3::MT5::Account;
use BOM::RPC::v3::NewAccount;
use BOM::RPC::v3::Notification;
use BOM::RPC::v3::P2P;
use BOM::RPC::v3::PaymentMethods;
use BOM::RPC::v3::PortfolioManagement;
use BOM::RPC::v3::Pricing;
use BOM::RPC::v3::Static;
use BOM::RPC::v3::TickStreamer;
use BOM::RPC::v3::Trading;
use BOM::RPC::v3::Wallets;
use BOM::RPC::v3::Transaction;
use BOM::RPC::v3::IdentityVerification;
use BOM::RPC::v3::Utility qw(log_exception);
use BOM::Transaction::Validation;
use BOM::User::Client;
use Brands;
use BOM::RPC::v3::Debug;

use constant REQUEST_ARGUMENTS_TO_BE_IGNORED => qw (req_id passthrough);
use Log::Any qw($log);

BOM::RPC::Registry::register(longcode => \&BOM::RPC::v3::Utility::longcode);

STDERR->autoflush(1);
STDOUT->autoflush(1);

=head2 wrap_rpc_sub

    $code = wrap_rpc_sub($def)

    $result = $code->(@args)

Given a single service definition for one RPC method, returns a C<CODE>
reference for invoking it. The returned function executes synchronously,
eventually returning the result of the RPC, even for asynchronous methods.

=over 4

=item * - C<def> - Service definition for the RPC method

=back

=cut

sub wrap_rpc_sub {
    my ($def) = @_;

    my $method = $def->name;

    return sub {
        my @original_args = @_;
        my $params        = $original_args[0] // {};
        my $log_context   = $original_args[1] // {};
        my $tv            = [Time::HiRes::gettimeofday];

        $params->{profile}->{rpc_send_rpcproc} = Time::HiRes::gettimeofday if $params->{is_profiling};

        $params->{token} = _get_token_by_loginid($params);

        foreach (REQUEST_ARGUMENTS_TO_BE_IGNORED) {
            delete $params->{args}{$_};
        }

        my $token_instance = BOM::Platform::Token::API->new;
        $params->{token_details} = $token_instance->get_client_details_from_token($params->{token});
        # set request log context for RPC methods
        set_request_logger_context($params->{token_details}, $log_context);
        set_current_context($params);

        if (exists $params->{server_name}) {
            $params->{website_name} = BOM::RPC::v3::Utility::website_name(delete $params->{server_name});
        }

        my $verify_app_res;
        if ($params->{valid_source}) {
            $params->{source} = $params->{valid_source};
        } elsif ($params->{source}) {
            $verify_app_res = BOM::RPC::v3::App::verify_app({app_id => $params->{source}});
            return $verify_app_res if $verify_app_res->{error};
        }

        my $result_auth = _check_authorization($def, $params);
        return $result_auth->{error} if $result_auth->{status} == 0;
        $params->{client} = $result_auth->{result}{client};
        $params->{app_id} = $result_auth->{result}{app_id};

        my $auth_timing = 1000 * Time::HiRes::tv_interval($tv);

        my @args = @original_args;
        my $result;
        try {
            my $code = $def->code;
            if ($def->is_async) {
                $result = $code->(@args)->get;
            } else {
                $result = $code->(@args);
            }
        } catch ($error) {
            $result = _handle_error($error, $def, \@original_args, $method);
        }

        if ($verify_app_res && ref $result eq 'HASH' && !$result->{error}) {
            $result->{stash} = {%{$result->{stash} // {}}, %{$verify_app_res->{stash}}};
        }

        $result->{auth_time} = $auth_timing if ref $result eq 'HASH' && $result->{rpc_time};

        if ($params->{is_profiling}) {
            $result->{passthrough}->{profile} = {
                $params->{profile}->%*,
                rpc_receive_rpcproc => scalar Time::HiRes::gettimeofday,
            };
        }

        return $result;
    };
}

=head2 set_request_logger_context

the context hashref will be set for Deriv adapter context 
so it can be appended with all log messages for RPC request

=over 2

=item * C<$token_details> - token information of authorize user

=item * C<$context> - hashref of contexual inforamation added for logging purpose

=back 

=cut

sub set_request_logger_context {
    my ($token_details, $context) = @_;
    if ($token_details) {
        $context->{loginid} = $token_details->{loginid};
    }
    $log->adapter->set_context($context) if $log->adapter->can('set_context');
}

=head2 set_current_context

    set_current_context($params)

Sets the current context for the RPC call. This includes the country, language, brand, broker_code and source.

=over 4

=item * - C<params> - Hashref of parameters passed to the RPC method

=back

=cut

sub set_current_context {
    my ($params) = @_;

    my $args = {};
    $args->{country_code} = $params->{country}  if exists $params->{country};
    $args->{language}     = $params->{language} if $params->{language};
    $args->{source}       = $params->{valid_source} // $params->{source};

    $args->{brand_name} = Brands->new(
        name   => $params->{brand},
        app_id => $params->{source},
    )->name;

    my $token_details = $params->{token_details};
    if ($token_details and exists $token_details->{loginid} and $token_details->{loginid} =~ /^(\D+)\d+$/) {
        $args->{broker_code} = $1;
    }

    my $r = BOM::Platform::Context::Request->new($args);
    BOM::Platform::Context::request($r);

    return;
}

=head2 _check_authorization

    $result = _check_authorization($def, $params)

Checks if a client object is defined on params. If so, validate client object.
When the client object is not defined, create a client instance, validate the client.
On success return the client object and the app_id.

=over 4

=item * - C<def> - Service definition for the RPC method

=item * - C<params> - Hashref of parameters passed to the RPC method

=back


=cut

sub _check_authorization {
    my ($def, $params) = @_;

    return {status => 1} if !($def->auth and $def->auth->@*);

    my $db_operation = $def->is_readonly ? 'replica' : 'write';

    my $client = $params->{client};
    my $app_id = $params->{app_id};

    if ($client) {
        # If there is a $client object but is not a Valid BOM::User::Client we return an error
        unless (blessed $client && $client->isa('BOM::User::Client')) {
            return {
                status => 0,
                error  => BOM::RPC::v3::Utility::create_error({
                        code              => 'InvalidRequest',
                        message_to_client => localize("Invalid request.")})};
        }
        $client->set_db($db_operation);
    } else {
        # If there is no $client, we continue with our auth check
        my $token_details = $params->{token_details};
        return {
            status => 0,
            error  => BOM::RPC::v3::Utility::invalid_token_error()}
            unless $token_details and exists $token_details->{loginid};

        $client = BOM::User::Client->get_client_instance($token_details->{loginid}, $db_operation);

        if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
            return {
                status => 0,
                error  => $auth_error
            };
        }

        unless (BOM::Config::Runtime->instance->app_config->system->suspend->wallets) {
            my @auth = $def->auth->@*;
            unless (($client->can_trade and any { $_ eq 'trading' } @auth) or ($client->is_wallet and any { $_ eq 'wallet' } @auth)) {
                return {
                    status => 0,
                    error  => BOM::RPC::v3::Utility::create_error({
                            code              => 'PermissionDenied',
                            message_to_client => localize('This resource cannot be accessed by this account type.')})};
            }
        }

        $app_id = $token_details->{app_id};
    }
    return {
        status => 1,
        result => {
            client => $client,
            app_id => $app_id
        }};
}

=head2 _get_token_by_loginid {

    $token = _get_token_by_loginid($params)

When account_tokens is defined, it will get the token by loginid if provided.
When no account_tokens are provided or no loginid is present, it will return the token from the authorize argument.

=over 4

=item * - C<params> - Hashref of parameters passed to the RPC method

=back

=cut

sub _get_token_by_loginid {
    my ($params) = @_;

    my $loginid        = delete $params->{args}->{loginid};
    my $token          = $params->{token};
    my $account_tokens = $params->{account_tokens};

    # After authorize call, and there's only 1 token provided.
    if ($token && $account_tokens && keys $account_tokens->%* > 1 && !$loginid) {
        return $token;
    }

    # After authorize call, and more than 1 token provided, use the loginid param if present.
    if ($loginid) {
        return $account_tokens->{$loginid}{token};
    }

    # For authorize call, set the token from the authorize argument.
    $token = $params->{args}->{authorize} if !$token && $params->{args}->{authorize};

    # Return token for authorize call or when no loginid is present.
    return $token;
}

=head2 _handle_error

    $result = _handle_error($error, $def, $original_args, $method)

Given an error object, returns a hashref suitable for returning to the client

=over 4

=item * - C<error> - Error object

=item * - C<def> - Service definition for the RPC method

=item * - C<original_args> - Original arguments passed to the RPC method

=item * - C<method> - Name of the RPC method

=back

=cut

sub _handle_error {
    my ($error, $def, $original_args, $method) = @_;

    return $error if ref $error eq 'HASH' and ref $error->{error} eq 'HASH';

    if (blessed($error) && $error->isa('BOM::Product::Exception')) {
        return BOM::RPC::v3::Utility::create_error({
            code              => $error->error_code,
            message_to_client => localize($error->message_to_client),
            ($error->details ? (details => $error->details) : ()),
        });
    }

    my $params = {$original_args->[0] ? %{$original_args->[0]} : ()};

    if (eval { $params->{client}->can('loginid') }) {
        $params->{client} = blessed($params->{client}) . ' object: ' . $params->{client}->loginid;
    }

    my $error_msg = "Exception when handling $method" . (defined $params->{client} ? " for $params->{client}." : '.');
    $error_msg .= " $error";
    warn $error_msg;

    log_exception(sprintf('%s::%s', $def->caller, $def->name));

    return BOM::RPC::v3::Utility::create_error({
            code              => 'InternalServerError',
            message_to_client => localize("Sorry, an error occurred while processing your request.")});
}

1;
