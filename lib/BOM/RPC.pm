package BOM::RPC;

use strict;
use warnings;
no indirect;

use List::Util qw(any);
use Log::Any::Adapter qw(Stderr), log_level => 'info';
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
use BOM::RPC::v3::Transaction;
use BOM::RPC::v3::IdentityVerification;
use BOM::RPC::v3::Utility qw(log_exception);
use BOM::Transaction::Validation;
use BOM::User::Client;
use Brands;

# TODO(leonerd): Maybe guard this by a flag of some kind so it isn't loaded by
# default?
use BOM::RPC::v3::Debug;

use constant REQUEST_ARGUMENTS_TO_BE_IGNORED => qw (req_id passthrough);

# TODO(leonerd): this one RPC is unusual, coming from Utility.pm which doesn't
# contain any other RPCs
BOM::RPC::Registry::register(longcode => \&BOM::RPC::v3::Utility::longcode);

STDERR->autoflush(1);
STDOUT->autoflush(1);

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

=head2 wrap_rpc_sub

    $code = wrap_rpc_sub($def)

    $result = $code->(@args)

Given a single service definition for one RPC method, returns a C<CODE>
reference for invoking it. The returned function executes synchronously,
eventually returning the result of the RPC, even for asynchronous methods.

=cut

# TODO(leonerd): Allow this to be async-returning for Futures
sub wrap_rpc_sub {
    my ($def) = @_;

    my $method = $def->name;

    return sub {
        my @original_args = @_;
        my $params        = $original_args[0] // {};

        my $tv = [Time::HiRes::gettimeofday];

        $params->{profile}->{rpc_send_rpcproc} = Time::HiRes::gettimeofday if $params->{is_profiling};

        $params->{token} = $params->{args}->{authorize} if !$params->{token} && $params->{args}->{authorize};

        foreach (REQUEST_ARGUMENTS_TO_BE_IGNORED) {
            delete $params->{args}{$_};
        }

        $params->{token_details} = BOM::RPC::v3::Utility::get_token_details($params->{token});

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

        if ($def->auth and $def->auth->@*) {
            if (my $client = $params->{client}) {
                # If there is a $client object but is not a Valid BOM::User::Client we return an error
                unless (blessed $client && $client->isa('BOM::User::Client')) {
                    return BOM::RPC::v3::Utility::create_error({
                            code              => 'InvalidRequest',
                            message_to_client => localize("Invalid request.")});
                }
            } else {
                # If there is no $client, we continue with our auth check
                my $token_details = $params->{token_details};
                return BOM::RPC::v3::Utility::invalid_token_error()
                    unless $token_details and exists $token_details->{loginid};

                my $client = BOM::User::Client->get_client_instance($token_details->{loginid});

                if (my $auth_error = BOM::RPC::v3::Utility::check_authorization($client)) {
                    return $auth_error;
                }

                unless (BOM::Config::Runtime->instance->app_config->system->suspend->wallets) {
                    my @auth = $def->auth->@*;
                    unless (($client->can_trade and any { $_ eq 'trading' } @auth) or ($client->is_wallet and any { $_ eq 'wallet' } @auth)) {
                        return BOM::RPC::v3::Utility::create_error({
                                code              => 'PermissionDenied',
                                message_to_client => localize('This resource cannot be accessed by this account type.')});
                    }
                }

                $params->{client} = $client;
                $params->{app_id} = $token_details->{app_id};
            }
        }

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
            #Future->fail()  will raise exception here, in this case error is already formatted
            #otherwise die again, let outer catch handle it.
            if (ref $error eq 'HASH' and ref $error->{error} eq 'HASH') {
                $result = $error;
            } else {
                # replacing possible objects in $params with strings to avoid error in encode_json function
                my $params = {$original_args[0] ? %{$original_args[0]} : ()};
                $params->{client} = blessed($params->{client}) . ' object: ' . $params->{client}->loginid
                    if eval { $params->{client}->can('loginid') };

                my $error_msg = "Exception when handling $method" . (defined $params->{client} ? " for $params->{client}." : '.');

                if (   $ENV{LOG_DETAILED_EXCEPTION}
                    or exists $params->{logging}{all}
                    or exists $params->{logging}{method}{$method}
                    or exists $params->{logging}{loginid}{$params->{token_details}{loginid} // ''}
                    or exists $params->{logging}{app_id}{$params->{source} // ''})
                {
                    $error_msg .= " $error";
                }
                warn $error_msg;

                log_exception(sprintf('%s::%s', $def->caller, $def->name));

                $result = BOM::RPC::v3::Utility::create_error({
                        code              => 'InternalServerError',
                        message_to_client => localize("Sorry, an error occurred while processing your request.")});
            }
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

1;
