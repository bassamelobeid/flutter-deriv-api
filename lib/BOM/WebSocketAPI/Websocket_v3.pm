package BOM::WebSocketAPI::Websocket_v3;

use Mojo::Base 'Mojolicious::Controller';

use BOM::WebSocketAPI::v3::Symbols;
use BOM::WebSocketAPI::v3::Authorize;
use BOM::WebSocketAPI::v3::ContractDiscovery;
use BOM::WebSocketAPI::v3::System;
use BOM::WebSocketAPI::v3::Accounts;
use BOM::WebSocketAPI::v3::MarketDiscovery;
use BOM::WebSocketAPI::v3::PortfolioManagement;
use BOM::WebSocketAPI::v3::Static;
use BOM::WebSocketAPI::v3::Cashier;
use BOM::WebSocketAPI::v3::NewAccount;
use DataDog::DogStatsd::Helper;
use JSON::Schema;
use File::Slurp;
use JSON;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(localize);
use BOM::Product::Transaction;
use Time::HiRes;

sub ok {
    my $c      = shift;
    my $source = 1;       # check http origin here
    $c->stash(source => $source);
    return 1;
}

sub entry_point {
    my $c = shift;

    my $log = $c->app->log;
    $log->debug("opening a websocket for " . $c->tx->remote_address);

    # enable permessage-deflate
    $c->tx->with_compression;

    $c->inactivity_timeout(120);
    # Increase inactivity timeout for connection a bit
    Mojo::IOLoop->singleton->stream($c->tx->connection)->timeout(120);

    $c->on(
        json => sub {
            my ($c, $p1) = @_;

            my $tag = 'origin:';
            my $data;
            my $send = 1;
            if (ref($p1) eq 'HASH') {

                if (my $origin = $c->req->headers->header("Origin")) {
                    if ($origin =~ /https?:\/\/([a-zA-Z0-9\.]+)$/) {
                        $tag = "origin:$1";
                    }
                }

                $data = _sanity_failed($c, $p1) || __handle($c, $p1, $tag);
                if (not $data) {
                    $send = undef;
                    $data = {};
                }

                if ($data->{error} and $data->{error}->{code} eq 'SanityCheckFailed') {
                    $data->{echo_req} = {};
                } else {
                    $data->{echo_req} = $p1;
                }
            } else {
                # for invalid call, eg: not json
                $data = $c->new_error('error', 'BadRequest', BOM::Platform::Context::localize('The application sent an invalid request.'));
                $data->{echo_req} = {};
            }
            $data->{version} = 3;

            my $l = length JSON::to_json($data);
            if ($l > 328000) {
                $data = $c->new_error('error', 'ResponseTooLarge', BOM::Platform::Context::localize('Response too large.'));
                $data->{echo_req} = $p1;
            }
            $log->info("Call from $tag, " . JSON::to_json(($data->{error}) ? $data : $data->{echo_req}));
            if ($send) {
                $c->send({json => $data});
            } else {
                return;
            }
        });

    # stop all recurring
    $c->on(
        finish => sub {
            my ($c) = @_;
            my $ws_id = $c->tx->connection;
            foreach my $id (keys %{$c->{ws}{$ws_id}}) {
                Mojo::IOLoop->remove($id);
            }
            delete $c->{ws}{$ws_id};
            delete $c->{fmb_ids}{$ws_id};
        });

    return;
}

sub __handle {
    my ($c, $p1, $tag) = @_;

    my $log = $c->app->log;
    $log->debug("websocket got json " . $c->dumper($p1));

    # [param key, sub, require auth, unauth-error-code]
    my @dispatch = (
        ['authorize',               \&BOM::WebSocketAPI::v3::Authorize::authorize,                        0],
        ['ticks',                   \&BOM::WebSocketAPI::v3::MarketDiscovery::ticks,                      0],
        ['ticks_history',           \&BOM::WebSocketAPI::v3::MarketDiscovery::ticks_history,              0],
        ['proposal',                \&BOM::WebSocketAPI::v3::MarketDiscovery::proposal,                   0],
        ['forget',                  \&BOM::WebSocketAPI::v3::System::forget,                              0],
        ['forget_all',              \&BOM::WebSocketAPI::v3::System::forget_all,                          0],
        ['ping',                    \&BOM::WebSocketAPI::v3::System::ping,                                0],
        ['time',                    \&BOM::WebSocketAPI::v3::System::server_time,                         0],
        ['payout_currencies',       \&BOM::WebSocketAPI::v3::ContractDiscovery::payout_currencies,        0],
        ['active_symbols',          \&BOM::WebSocketAPI::v3::Symbols::active_symbols,                     0],
        ['contracts_for',           \&BOM::WebSocketAPI::v3::ContractDiscovery::contracts_for,            0],
        ['trading_times',           \&BOM::WebSocketAPI::v3::MarketDiscovery::trading_times,              0],
        ['asset_index',             \&BOM::WebSocketAPI::v3::MarketDiscovery::asset_index,                0],
        ['residence_list',          \&BOM::WebSocketAPI::v3::Static::residence_list,                      0],
        ['states_list',             \&BOM::WebSocketAPI::v3::Static::states_list,                         0],
        ['landing_company',         \&BOM::WebSocketAPI::v3::Accounts::landing_company,                   0],
        ['landing_company_details', \&BOM::WebSocketAPI::v3::Accounts::landing_company_details,           0],
        ['verify_email',            \&BOM::WebSocketAPI::v3::NewAccount::verify_email,                    0],
        ['new_account_virtual',     \&BOM::WebSocketAPI::v3::NewAccount::new_account_virtual,             0],
        ['buy',                     \&BOM::WebSocketAPI::v3::PortfolioManagement::buy,                    1],
        ['sell',                    \&BOM::WebSocketAPI::v3::PortfolioManagement::sell,                   1],
        ['portfolio',               \&BOM::WebSocketAPI::v3::PortfolioManagement::portfolio,              1],
        ['proposal_open_contract',  \&BOM::WebSocketAPI::v3::PortfolioManagement::proposal_open_contract, 1],
        ['balance',                 \&BOM::WebSocketAPI::v3::Accounts::balance,                           1],
        ['statement',               \&BOM::WebSocketAPI::v3::Accounts::statement,                         1],
        ['profit_table',            \&BOM::WebSocketAPI::v3::Accounts::profit_table,                      1],
        ['get_account_status',      \&BOM::WebSocketAPI::v3::Accounts::get_account_status,                1],
        ['change_password',         \&BOM::WebSocketAPI::v3::Accounts::change_password,                   1],
        ['get_settings',            \&BOM::WebSocketAPI::v3::Accounts::get_settings,                      1],
        ['set_settings',            \&BOM::WebSocketAPI::v3::Accounts::set_settings,                      1],
        ['get_limits',              \&BOM::WebSocketAPI::v3::Cashier::get_limits,                         1],
        ['new_account_real',        \&BOM::WebSocketAPI::v3::NewAccount::new_account_real,                1],
    );

    foreach my $dispatch (@dispatch) {
        next unless exists $p1->{$dispatch->[0]};
        my $t0        = [Time::HiRes::gettimeofday];
        my $f         = '/home/git/regentmarkets/bom-websocket-api/config/v3/' . $dispatch->[0];
        my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/send.json")), format => \%JSON::Schema::FORMATS);

        if (not $validator->validate($p1)) {
            my $validation_errors = $validator->validate($p1);

            my ($details, @general);
            foreach my $err ($validation_errors->errors) {
                if ($err->property =~ /\$\.(.+)$/) {
                    $details->{$1} = $err->message;
                } else {
                    push @general, $err->message;
                }
            }
            my $message = BOM::Platform::Context::localize('Input validation failed: ') . join(', ', (keys %$details, @general));
            return $c->new_error('error', 'InputValidationFailed', $message, $details);
        }

        DataDog::DogStatsd::Helper::stats_inc('websocket_api.call.' . $dispatch->[0], {tags => [$tag]});
        DataDog::DogStatsd::Helper::stats_inc('websocket_api.call.all',               {tags => [$tag]});

        ## refetch account b/c stash client won't get updated in websocket
        if ($dispatch->[2] and my $loginid = $c->stash('loginid')) {
            my $client = BOM::Platform::Client->new({loginid => $loginid});
            return $c->new_error('error', 'InvalidClient', BOM::Platform::Context::localize('Invalid client account.')) unless $client;
            return $c->new_error('error', 'DisabledClient', BOM::Platform::Context::localize('This account is unavailable.'))
                if $client->get_status('disabled');
            $c->stash(
                client  => $client,
                account => $client->default_account // undef
            );
        }

        if ($dispatch->[2] and not $c->stash('client')) {
            return $c->new_error($dispatch->[0], 'AuthorizationRequired', BOM::Platform::Context::localize('Please log in.'));
        }

        ## sell expired
        if (grep { $_ eq $dispatch->[0] } ('portfolio', 'statement', 'profit_table')) {
            if (BOM::Platform::Runtime->instance->app_config->quants->features->enable_portfolio_autosell) {
                BOM::Product::Transaction::sell_expired_contracts({
                    client => $c->stash('client'),
                    source => $c->stash('source'),
                });
            }
        }

        my $result = $dispatch->[1]->($c, $p1);

        $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")), format => \%JSON::Schema::FORMATS);
        if ($result and not $validator->validate($result)) {
            my $validation_errors = $validator->validate($result);
            my $error;
            $error .= " - $_" foreach $validation_errors->errors;
            $log->warn("Invalid output parameter for [ " . JSON::to_json($result) . " error: $error ]");
            return $c->new_error('OutputValidationFailed', BOM::Platform::Context::localize("Output validation failed: ") . $error);
        }
        $result->{debug} = [Time::HiRes::tv_interval($t0), ($c->stash('client') ? $c->stash('client')->loginid : '')] if ref $result;
        return $result;
    }

    $log->debug("unrecognised request: " . $c->dumper($p1));
    return $c->new_error('error', 'UnrecognisedRequest', BOM::Platform::Context::localize('Unrecognised request.'));
}

sub _failed_key_value {
    my ($key, $value) = @_;

    if ($key !~ /^[A-Za-z0-9_-]{1,25}$/ or $value !~ /^[\s\.A-Za-z0-9\@_:+-\/=']{0,256}$/) {
        return ($key, $value);
    }
    return;
}

sub _sanity_failed {
    my ($c, $arg) = @_;
    my @failed;

    OUTER:
    foreach my $k (keys %$arg) {
        if (not ref $arg->{$k}) {
            last OUTER if (@failed = _failed_key_value($k, $arg->{$k}));
        } else {
            foreach my $l (keys %{$arg->{$k}}) {
                last OUTER if (@failed = _failed_key_value($l, $arg->{$k}->{$l}));
            }
        }
    }

    if (@failed) {
        $c->app->log->warn("Sanity check failed: $failed[0] -> $failed[1]");
        return $c->new_error('sanity_check', 'SanityCheckFailed', BOM::Platform::Context::localize("Parameters sanity check failed."));
    }
    return;
}

1;
