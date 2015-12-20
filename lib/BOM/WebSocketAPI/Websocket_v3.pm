package BOM::WebSocketAPI::Websocket_v3;

use Mojo::Base 'Mojolicious::Controller';

use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use BOM::WebSocketAPI::v3::Wrapper::Transaction;
use BOM::WebSocketAPI::v3::Wrapper::Offerings;
use BOM::WebSocketAPI::v3::Wrapper::Authorize;
use BOM::WebSocketAPI::v3::Wrapper::System;
use BOM::WebSocketAPI::v3::Wrapper::Accounts;
use BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;
use BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;
use BOM::WebSocketAPI::v3::Wrapper::Static;
use BOM::WebSocketAPI::v3::Wrapper::Cashier;
use BOM::WebSocketAPI::v3::Wrapper::NewAccount;
use DataDog::DogStatsd::Helper;
use JSON::Schema;
use File::Slurp;
use JSON;
use BOM::Platform::Runtime;
use BOM::Product::Transaction;
use Time::HiRes;
use BOM::Database::Rose::DB;
use Data::UUID;
use Time::Out qw(timeout);

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
    Mojo::IOLoop->singleton->max_connections(100000);

    if (not $c->stash->{redis}) {
        state $url = do {
            my $cf = YAML::XS::LoadFile('/etc/rmg/chronicle.yml')->{read};
            defined($cf->{password})
                ? "redis://dummy:$cf->{password}\@$cf->{host}:$cf->{port}"
                : "redis://$cf->{host}:$cf->{port}";
        };

        my $redis = Mojo::Redis2->new(url => $url);
        $redis->on(
            error => sub {
                my ($self, $err) = @_;
                warn("error: $err");
            });
        $redis->on(
            message => sub {
                my ($self, $msg, $channel) = @_;

                # set correct request context for localize
                BOM::Platform::Context::request($c->stash('request'))
                    if $channel =~ /^FEED::/;

                BOM::WebSocketAPI::v3::Wrapper::Accounts::send_realtime_balance($c, $msg) if $channel =~ /^TXNUPDATE::balance_/;
                BOM::WebSocketAPI::v3::Wrapper::Streamer::process_realtime_events($c, $msg) if $channel =~ /^FEED::/;
            });
        $c->stash->{redis} = $redis;
    }

    $c->on(
        json => sub {
            my ($c, $p1) = @_;

            BOM::Platform::Context::request($c->stash('request'));

            my $tag = 'origin:';
            my $data;
            my $send = 1;
            if (ref($p1) eq 'HASH') {

                if (my $origin = $c->req->headers->header("Origin")) {
                    if ($origin =~ /https?:\/\/([a-zA-Z0-9\.]+)$/) {
                        $tag = "origin:$1";
                    }
                }

                $c->stash('args' => $p1);

                timeout 15 => sub {
                    $data = _sanity_failed($c, $p1) || __handle($c, $p1, $tag);
                };
                if ($@) {
                    $c->app->log->info("$$ timeout for " . JSON::to_json($p1));
                }

                if (not $data) {
                    $send = undef;
                    $data = {};
                }

                if ($data->{error} and $data->{error}->{code} eq 'SanityCheckFailed') {
                    $data->{echo_req} = {};
                } else {
                    $data->{echo_req} = $p1;
                }
                $data->{req_id} = $p1->{req_id} if (exists $p1->{req_id});
            } else {
                # for invalid call, eg: not json
                $data = $c->new_error('error', 'BadRequest', $c->l('The application sent an invalid request.'));
                $data->{echo_req} = {};
            }
            $data->{version} = 3;

            my $l = length JSON::to_json($data);
            if ($l > 328000) {
                $data = $c->new_error('error', 'ResponseTooLarge', $c->l('Response too large.'));
                $data->{echo_req} = $p1;
            }
            if ($send) {
                $c->send({json => $data});
            }

            BOM::Database::Rose::DB->db_cache->finish_request_cycle;
            return;
        });

    # stop all recurring
    $c->on(
        finish => sub {
            my $c = shift;
            if ($c->tx) {
                my $ws_id = $c->tx->connection;
                foreach my $id (keys %{$c->{ws}{$ws_id}}) {
                    Mojo::IOLoop->remove($id);
                }
                delete $c->stash->{redis};
                delete $c->{ws}{$ws_id};
                delete $c->{fmb_ids}{$ws_id};
            }
        });

    return;
}

sub __handle {
    my ($c, $p1, $tag) = @_;

    my $log = $c->app->log;
    $log->debug("websocket got json " . $c->dumper($p1));

    # [param key, sub, require auth, unauth-error-code]
    my @dispatch = (
        ['authorize',               \&BOM::WebSocketAPI::v3::Wrapper::Authorize::authorize,              0],
        ['logout',                  \&BOM::WebSocketAPI::v3::Wrapper::Authorize::logout,                 0],
        ['trading_times',           \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::trading_times,    0],
        ['asset_index',             \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::asset_index,      0],
        ['active_symbols',          \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::active_symbols,   0],
        ['ticks',                   \&BOM::WebSocketAPI::v3::Wrapper::Streamer::ticks,                   0],
        ['ticks_history',           \&BOM::WebSocketAPI::v3::Wrapper::Streamer::ticks_history,           0],
        ['proposal',                \&BOM::WebSocketAPI::v3::Wrapper::Streamer::proposal,                0],
        ['forget',                  \&BOM::WebSocketAPI::v3::Wrapper::System::forget,                    0],
        ['forget_all',              \&BOM::WebSocketAPI::v3::Wrapper::System::forget_all,                0],
        ['ping',                    \&BOM::WebSocketAPI::v3::Wrapper::System::ping,                      0],
        ['time',                    \&BOM::WebSocketAPI::v3::Wrapper::System::server_time,               0],
        ['contracts_for',           \&BOM::WebSocketAPI::v3::Wrapper::Offerings::contracts_for,          0],
        ['residence_list',          \&BOM::WebSocketAPI::v3::Wrapper::Static::residence_list,            0],
        ['states_list',             \&BOM::WebSocketAPI::v3::Wrapper::Static::states_list,               0],
        ['payout_currencies',       \&BOM::WebSocketAPI::v3::Wrapper::Accounts::payout_currencies,       0],
        ['landing_company',         \&BOM::WebSocketAPI::v3::Wrapper::Accounts::landing_company,         0],
        ['landing_company_details', \&BOM::WebSocketAPI::v3::Wrapper::Accounts::landing_company_details, 0],
        ['paymentagent_list',       \&BOM::WebSocketAPI::v3::Wrapper::Cashier::paymentagent_list,        0],
        ['verify_email',            \&BOM::WebSocketAPI::v3::Wrapper::NewAccount::verify_email,          0],
        ['new_account_virtual',     \&BOM::WebSocketAPI::v3::Wrapper::NewAccount::new_account_virtual,   0],
        # authenticated calls
        ['sell',                      \&BOM::WebSocketAPI::v3::Wrapper::Transaction::sell,                           1],
        ['buy',                       \&BOM::WebSocketAPI::v3::Wrapper::Transaction::buy,                            1],
        ['portfolio',                 \&BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::portfolio,              1],
        ['proposal_open_contract',    \&BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::proposal_open_contract, 1],
        ['balance',                   \&BOM::WebSocketAPI::v3::Wrapper::Accounts::balance,                           1],
        ['statement',                 \&BOM::WebSocketAPI::v3::Wrapper::Accounts::statement,                         1],
        ['profit_table',              \&BOM::WebSocketAPI::v3::Wrapper::Accounts::profit_table,                      1],
        ['get_account_status',        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::get_account_status,                1],
        ['change_password',           \&BOM::WebSocketAPI::v3::Wrapper::Accounts::change_password,                   1],
        ['get_settings',              \&BOM::WebSocketAPI::v3::Wrapper::Accounts::get_settings,                      1],
        ['set_settings',              \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_settings,                      1],
        ['get_self_exclusion',        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::get_self_exclusion,                1],
        ['set_self_exclusion',        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion,                1],
        ['cashier_password',          \&BOM::WebSocketAPI::v3::Wrapper::Accounts::cashier_password,                  1],
        ['api_token',                 \&BOM::WebSocketAPI::v3::Wrapper::Accounts::api_token,                         1],
        ['get_limits',                \&BOM::WebSocketAPI::v3::Wrapper::Cashier::get_limits,                         1],
        ['paymentagent_withdraw',     \&BOM::WebSocketAPI::v3::Wrapper::Cashier::paymentagent_withdraw,              1],
        ['paymentagent_transfer',     \&BOM::WebSocketAPI::v3::Wrapper::Cashier::paymentagent_transfer,              1],
        ['transfer_between_accounts', \&BOM::WebSocketAPI::v3::Wrapper::Cashier::transfer_between_accounts,          1],
        ['new_account_real',          \&BOM::WebSocketAPI::v3::Wrapper::NewAccount::new_account_real,                1],
        ['new_account_maltainvest',   \&BOM::WebSocketAPI::v3::Wrapper::NewAccount::new_account_maltainvest,         1],
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
            my $message = $c->l('Input validation failed: ') . join(', ', (keys %$details, @general));
            return $c->new_error('error', 'InputValidationFailed', $message, $details);
        }

        DataDog::DogStatsd::Helper::stats_inc('websocket_api.call.' . $dispatch->[0], {tags => [$tag]});
        DataDog::DogStatsd::Helper::stats_inc('websocket_api.call.all',               {tags => [$tag]});

        ## refetch account b/c stash client won't get updated in websocket
        if ($dispatch->[2] and my $loginid = $c->stash('loginid')) {
            my $client = BOM::Platform::Client->new({loginid => $loginid});
            return $c->new_error('error', 'InvalidClient', $c->l('Invalid client account.')) unless $client;
            return $c->new_error('error', 'DisabledClient', $c->l('This account is unavailable.'))
                if $client->get_status('disabled');
            $c->stash(
                client  => $client,
                account => $client->default_account // undef
            );

            my $self_excl = $client->get_self_exclusion;
            my $lim;
            if ($self_excl and $lim = $self_excl->exclude_until and Date::Utility->new->is_before(Date::Utility->new($lim))) {
                return $c->new_error('error', 'ClientSelfExclusion', $c->l('Sorry, you have excluded yourself until [_1].', $lim));
            }
        }

        if ($dispatch->[2] and not $c->stash('client')) {
            return $c->new_error($dispatch->[0], 'AuthorizationRequired', $c->l('Please log in.'));
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
            return $c->new_error('OutputValidationFailed', $c->l("Output validation failed: ") . $error);
        }
        $result->{debug} = [Time::HiRes::tv_interval($t0), ($c->stash('client') ? $c->stash('client')->loginid : '')] if ref $result;
        return $result;
    }

    $log->debug("unrecognised request: " . $c->dumper($p1));
    return $c->new_error('error', 'UnrecognisedRequest', $c->l('Unrecognised request.'));
}

sub _failed_key_value {
    my ($key, $value) = @_;

    # allow all printable ASCII char for password
    state %pwd_field;
    %pwd_field = map { $_ => 1 } qw( client_password old_password new_password unlock_password lock_password ) if (not %pwd_field);

    if ($pwd_field{$key}) {
        return;
    } elsif ($key !~ /^[A-Za-z0-9_-]{1,50}$/ or $value !~ /^[\s\.A-Za-z0-9\@_:+-\/='&\$]{0,256}$/) {
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
            if (ref $arg->{$k} eq 'HASH') {
                foreach my $l (keys %{$arg->{$k}}) {
                    last OUTER if (@failed = _failed_key_value($l, $arg->{$k}->{$l}));
                }
            } elsif (ref $arg->{$k} eq 'ARRAY') {
                foreach my $l (@{$arg->{$k}}) {
                    last OUTER if (@failed = _failed_key_value($k, $l));
                }
            }
        }
    }

    if (@failed) {
        $c->app->log->warn("Sanity check failed: $failed[0] -> $failed[1]");
        return $c->new_error('sanity_check', 'SanityCheckFailed', $c->l("Parameters sanity check failed."));
    }
    return;
}

1;
