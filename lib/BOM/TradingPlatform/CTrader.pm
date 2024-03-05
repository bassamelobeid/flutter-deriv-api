package BOM::TradingPlatform::CTrader;

use strict;
use warnings;
no indirect;

use Digest::SHA1 qw(sha1_hex);
use Array::Utils qw(array_minus);
use List::Util   qw(first any uniq);
use Syntax::Keyword::Try;
use HTTP::Tiny;
use Carp                       qw(croak);
use Format::Util::Numbers      qw(financialrounding formatnumber);
use Log::Any                   qw($log);
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use YAML::XS;
use Data::Dumper;

use BOM::User::Client;
use BOM::Platform::Event::Emitter;
use BOM::Config::Redis;
use BOM::Platform::Token::API;
use BOM::Platform::Context                      qw (request);
use BOM::TradingPlatform::Helper::HelperCTrader qw(
    check_existing_account
    construct_new_trader_params
    construct_group_name
    get_ctrader_landing_company
    get_new_account_currency
    group_to_groupid
    is_valid_group
    traderid_from_traderlightlist
    get_ctrader_account_type
);

use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);

use parent qw(BOM::TradingPlatform);

=head1 NAME 

BOM::TradingPlatform::CTrader - The cTrader trading platform implementation.

=head1 SYNOPSIS 

    my $dx = BOM::TradingPlatform::CTrader->new(client => $client);

=head1 DESCRIPTION 

Provides a high level implementation of the cTrader API.

Exposes cTrader API through our trading platform interface.

This module must provide support to each cTrader integration within our systems.

=cut

use parent qw(BOM::TradingPlatform);

use constant {
    ONE_TIME_TOKEN_TIMEOUT     => 60,                                   # one time token takes 1 minute (60 seconds) to expire.
    ONE_TIME_TOKEN_LENGTH      => 20,
    ONE_TIME_TOKEN_KEY         => 'CTRADER::OAUTH::ONE_TIME_TOKEN::',
    PLATFORM_ID                => 'ctrader',
    HTTP_TIMEOUT               => 20,
    DEMO_TOPUP_MINIMUM_BALANCE => 1000,
    DEMO_TOPUP_AMOUNT          => 10000,
};

=head2 new

Creates and returns a new L<BOM::TradingPlatform::CTrader> instance.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {%args{qw(client user rule_engine)}}, $class;
}

=head2 active_servers

Returns servers that are not suspended.

=cut

sub active_servers {
    my $self    = shift;
    my $suspend = BOM::Config::Runtime->instance->app_config->system->ctrader->suspend;
    return qw(real demo) if $self->client and any { $self->client->email eq $_ } $suspend->user_exceptions->@*;
    return ()            if $suspend->all;
    my @servers = grep { !$suspend->$_ } qw(real demo);
    return @servers;
}

=head2 server_check

Throw appropriate errors if any @servers are not available.
In some cases we need to call this before calling the api, e.g. deposit.

=over 4

=item * C<servers> array of server such as [real, demo].

=back

=cut

sub server_check {
    my ($self, @servers) = @_;

    my @active_servers = $self->active_servers;

    if (array_minus(@servers, @active_servers)) {
        die +{error_code => 'CTraderSuspended'} if BOM::Config::Runtime->instance->app_config->system->ctrader->suspend->all;
        die +{error_code => 'CTraderServerSuspended'};
    }
}

=head2 generate_login_token

Generates one time login token for cTrader account.
Saves generated token into redis for short period of time.

=cut

sub generate_login_token {
    my ($self, $user_agent) = @_;

    croak 'user_agent is mandatory argument' unless defined $user_agent;

    my ($login) = $self->user->get_ctrader_loginids;

    die +{error_code => 'CTraderAccountNotFound'} unless $login;

    # Should never happen, it means we have corrupted data in db
    # But because it's json field we cannot enforce at DB level
    my $ctid_userid = $self->get_ctid_userid();
    die "ctid is not found for $login" unless $ctid_userid;

    my $one_time_token_params = +{
        ctid           => $ctid_userid,
        ua_fingerprint => $user_agent,
        user_id        => $self->user->id,
    };

    # 3 attempts just in case of collisions. Normally should be done from first attempt.
    my $redis = BOM::Config::Redis::redis_auth_write;
    for (1 .. 3) {
        my $one_time_token = BOM::Platform::Token::API->new->generate_token(ONE_TIME_TOKEN_LENGTH);

        my $saved = $redis->set(
            ONE_TIME_TOKEN_KEY . $one_time_token,
            encode_json_utf8($one_time_token_params),
            EX => ONE_TIME_TOKEN_TIMEOUT,
            'NX',
        );

        return $one_time_token if $saved;
    }

    die "Fail to generate cTrader login token";
}

=head2 decode_login_token

Validates and one time token and reurns decoded token payload.
In case  not valid token is provided, then exception will be raised.

=cut

sub decode_login_token {
    my ($class, $token) = @_;

    die "INVALID_TOKEN\n" unless length($token // '') == ONE_TIME_TOKEN_LENGTH;

    my $redis = BOM::Config::Redis::redis_auth_write;

    # we need after update to redis 6.2 we can replace with GETDEL  command.
    # For now transaction is the only way to guarantee one time usage
    $redis->multi;
    $redis->get(ONE_TIME_TOKEN_KEY . $token);
    $redis->del(ONE_TIME_TOKEN_KEY . $token);
    my ($payload) = $redis->exec->@*;

    die "INVALID_TOKEN\n" unless $payload;

    my $ott_params;
    try {
        $ott_params = decode_json_utf8($payload);
        # Should never happen, but we're reading data from external source, better to be safe than sorry.
        die if any { !defined $ott_params->{$_} } qw(ctid ua_fingerprint user_id);
    } catch {
        die "INVALID_TOKEN\n";
    }

    return $ott_params;
}

=head2 local_accounts

Returns ctrader account info from deriv db.

Takes the following named parameters:

=over 4

=item * C<ignore_wallet_links> if true, any wallet links will be ignored.

=back

=cut

sub local_accounts {
    my ($self, %args) = @_;

    my $login_details = $self->user->loginid_details;
    my @accounts      = sort grep { ($_->{platform} // '') eq PLATFORM_ID && !$_->{status} } values %$login_details;
    @accounts =
        grep { $_->{wallet_loginid} ? $self->client->is_wallet && $self->client->loginid eq $_->{wallet_loginid} : !$self->client->is_wallet }
        @accounts
        unless $args{ignore_wallet_links};
    return @accounts;
}

=head2 handle_api_error

Called when an unexpcted cTrader API error occurs. Dies with generic error code unless one is provided.

=cut

sub handle_api_error {
    my ($self, $resp, $error_code, %args) = @_;
    $args{password} = '<hidden>'                            if $args{password};
    $resp           = [$resp->@{qw/content reason status/}] if ref $resp eq 'HASH';
    stats_inc('ctrader.rpc_service.api_call_fail', {tags => ['server:' . $args{server}, 'method:' . $args{method}]});
    my $error_message = sprintf('ctrader call failed for %s: %s, call args: %s', $self->client->loginid, Dumper($resp), Dumper(\%args));
    $error_message =~ s/[a-zA-Z0-9.!#$%&’*+\/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+/*****/g;
    $log->warnf('%s', $error_message);
    die +{error_code => $error_code // 'CTraderGeneral'};
}

=head2 deposit

Transfer from our system to ctrader.

Takes the following arguments as named parameters:

=over 4

=item * C<amount> in deriv account currency.

=item * C<to_account>. Our ctrader account id.

=item * C<from_account>. Source account to deposit towards to_account.

=back

Returns transaction id in hashref.

=cut

sub deposit {
    my ($self, %args) = @_;

    my $account = first { $_->{loginid} eq $args{to_account} } $self->local_accounts
        or die +{error_code => 'CTraderInvalidAccount'};

    my $server = $account->{account_type};

    $self->server_check('real');    # try to avoid debiting deriv if server is not available
    my $deposit_suspend = BOM::Config::Runtime->instance->app_config->system->ctrader->suspend->deposits;
    die +{error_code => 'CTraderDepositSuspended'} if $deposit_suspend and $account->{account_type} eq 'real';

    return $self->demo_top_up($account) if $account->{account_type} eq 'demo' && !$account->{wallet_loginid};

    # Sequence:
    # 1. Validation
    # 2. Withdrawal from deriv
    # 3. Deposit to ctrader

    my $tx_amounts = $self->validate_transfer(
        action               => 'deposit',
        amount               => $args{amount},
        amount_currency      => $self->client->currency,
        platform_currency    => $account->{currency},
        request_currency     => $args{currency},                                                  # param is renamed here
        account_type         => $account->{account_type},
        currency             => $args{currency},
        payment_type         => 'ctrader_transfer',
        landing_company_from => $self->client->landing_company->short,
        landing_company_to   => $self->account_details_lite($account)->{landing_company_short},
        from_account         => $self->client->loginid,
        to_account           => $args{to_account},
    );

    my %txn_details = (
        ctrader_account_id        => $args{to_account},
        fees                      => $tx_amounts->{fees},
        fees_percent              => $tx_amounts->{fees_percent},
        fees_currency             => $self->client->account->currency_code,     # sending account
        min_fee                   => $tx_amounts->{min_fee},
        fee_calculated_by_percent => $tx_amounts->{fee_calculated_by_percent});

    my $remark = sprintf('Transfer from %s to cTrader account %s', $self->client->loginid, $args{to_account});

    my $child_table_ctrader_transfer = {
        ctrader_account_id => $args{to_account},
        ctrader_amount     => $tx_amounts->{recv_amount},
    };

    my $txn;
    try {
        $txn = $self->client_payment(
            payment_type  => 'ctrader_transfer',
            amount        => -$args{amount},                  # negative!
            fees          => $tx_amounts->{fees},
            remark        => $remark,
            txn_details   => \%txn_details,
            payment_child => $child_table_ctrader_transfer,
        );

        $self->user->daily_transfer_incr(
            amount          => $args{amount},
            amount_currency => $self->client->currency,
            loginid_from    => $self->client->loginid,
            loginid_to      => $args{to_account},
        );

    } catch {
        die +{error_code => 'CTraderDepositFailed'};
    }

    try {

        my %call_args = (
            server  => $server,
            method  => "tradermanager_deposit",
            payload => {
                traderId => $account->{attributes}->{trader_id},
                amount   => $tx_amounts->{recv_amount},
            });

        my $resp = $self->call_api(%call_args);

        $self->handle_api_error($resp, 'CTraderDepositFailed', %call_args) unless $resp->{balanceHistoryId};

    } catch {
        die +{error_code => 'CTraderDepositIncomplete'};
    }

    # get updated balance
    my $trader_details;
    try {

        $trader_details = $self->call_api(
            server  => $server,
            method  => 'trader_get',
            payload => {loginid => $account->{attributes}->{login}});

    } catch {
        die +{error_code => 'CTraderTransferCompleteError'};
    }

    my $account_details = {
        local_account   => $self->user->loginid_details->{$args{to_account}},
        ctrader_account => $trader_details
    };

    return {
        $self->account_details($account_details)->%*,
        transaction_id => $txn->id,
    };
}

=head2 withdraw

Transfer from ctrader to our system.

Takes the following arguments as named parameters:

=over 4

=item * C<amount> in ctrader account currency.

=item * C<from_account>. Our dxtrade account id.

=item * C<to_account>. Target account to deposit towards after withdraw from from_account.

=back

Returns transaction id in hashref.

=cut

sub withdraw {
    my ($self, %args) = @_;

    my $account = first { $_->{loginid} eq $args{from_account} } $self->local_accounts
        or die +{error_code => 'CTraderInvalidAccount'};

    my $server = $account->{account_type};

    $self->server_check('real');
    my $withdraw_suspend = BOM::Config::Runtime->instance->app_config->system->ctrader->suspend->withdrawals;
    die +{error_code => 'CTraderWithdrawalSuspended'} if $withdraw_suspend and $account->{account_type} eq 'real';

    # Sequence:
    # 1. Validation
    # 2. Withdraw from ctrader
    # 3. Deposit to deriv

    my $tx_amounts = $self->validate_transfer(
        action               => 'withdrawal',
        amount               => $args{amount},
        amount_currency      => $account->{currency},
        platform_currency    => $account->{currency},
        request_currency     => $args{currency},                                                  # param is renamed here
        account_type         => $account->{account_type},
        currency             => $args{currency},
        landing_company_from => $self->account_details_lite($account)->{landing_company_short},
        landing_company_to   => $self->client->landing_company->short,
        from_account         => $args{from_account},
        to_account           => $self->client->loginid,
    );

    my %call_args = (
        server  => $server,
        method  => "tradermanager_withdraw",
        payload => {
            traderId => $account->{attributes}->{trader_id},
            amount   => $args{amount},
        });

    my $resp = $self->call_api(%call_args, quiet => 1);

    die +{error_code => 'CTraderInsufficientBalance'}
        if $resp->{errorCode}
        and $resp->{errorCode} eq 'NOT_ENOUGH_MONEY';

    $self->handle_api_error($resp, 'CTraderWithdrawalFailed', %call_args) unless ($resp->{balanceHistoryId});

    my %txn_details = (
        ctrader_account_id        => $args{from_account},
        fees                      => $tx_amounts->{fees},
        fees_percent              => $tx_amounts->{fees_percent},
        fees_currency             => $account->{currency},                      # sending account
        min_fee                   => $tx_amounts->{min_fee},
        fee_calculated_by_percent => $tx_amounts->{fee_calculated_by_percent});

    my $remark = sprintf('Transfer from cTrader account %s to %s', $args{from_account}, $self->client->loginid);

    my $txn;
    try {

        my $child_table_ctrader_transfer = {
            ctrader_account_id => $args{from_account},
            ctrader_amount     => $args{amount} * -1,
        };

        $txn = $self->client_payment(
            payment_type  => 'ctrader_transfer',
            amount        => $tx_amounts->{recv_amount},
            fees          => $tx_amounts->{fees_in_client_currency},
            remark        => $remark,
            txn_details   => \%txn_details,
            payment_child => $child_table_ctrader_transfer,
        );

        $self->user->daily_transfer_incr(
            amount          => $args{amount},
            amount_currency => $account->{currency},
            loginid_from    => $args{from_account},
            loginid_to      => $self->client->loginid,
        );

    } catch {
        die +{error_code => 'CTraderWithdrawalIncomplete'};
    }

    # get updated balance
    my $trader_details;
    try {

        $trader_details = $self->call_api(
            server  => $server,
            method  => 'trader_get',
            payload => {loginid => $account->{attributes}->{login}});

    } catch {
        die +{error_code => 'CTraderTransferCompleteError'};
    }

    my $account_details = {
        local_account   => $self->user->loginid_details->{$args{from_account}},
        ctrader_account => $trader_details
    };

    return {
        $self->account_details($account_details)->%*,
        transaction_id => $txn->id,
    };
}

=head2 demo_top_up

Top up demo account.

=over 4

=item * C<account> account information from loginid_details.

=back

=cut

sub demo_top_up {
    my ($self, $account) = @_;
    my $server = $account->{account_type};

    my $check = $self->call_api(
        server  => $server,
        method  => 'trader_get',
        payload => {loginid => $account->{attributes}->{login}});

    die +{
        error_code     => 'CTraderDemoTopupBalance',
        message_params => [formatnumber('amount', 'USD', DEMO_TOPUP_MINIMUM_BALANCE), 'USD']}
        unless $check->{balance} <= DEMO_TOPUP_MINIMUM_BALANCE;

    my %call_args = (
        server  => $server,
        method  => "tradermanager_deposit",
        payload => {
            traderId => $account->{attributes}->{trader_id},
            amount   => DEMO_TOPUP_AMOUNT,
        });

    my $resp = $self->call_api(%call_args);

    $self->handle_api_error($resp, 'CTraderDepositFailed', %call_args) unless $resp->{balanceHistoryId};

    return;
}

=head2 account_details_lite

Format account details for websocket response.

=over 4

=item * C<account> account information from loginid_details.

=back

=cut

sub account_details_lite {
    my ($self, $account) = @_;

    return {
        account_type          => $account->{account_type},
        currency              => $account->{currency},
        platform              => PLATFORM_ID,
        market_type           => $account->{attributes}->{market_type},
        landing_company_short => $account->{attributes}->{landing_company},
    };
}

=head2 new_account

Creates a new cTrader account with a cTID account if necessary.

Takes the following arguments as named parameters:

# Field of interest
# email, name, lastName, leverageInCents*, address, state
# city, zipCode, countryId, depositCurrency*, phone
# hashedPassword*, accessRights*, groupName*, accountType
# balance, brokerName, enabled.

=over 4

=item * C<account_type> (required). "real" or "demo".

=item * C<market_type> (required). market type, currently only support "all"

=item * C<currency> Client's currency will be used if not provided.

=item * C<platfrom> Platform name - ctrader

=item * C<company> Landing company to create account for. Example: svg

=back

Returns new account fields formatted for wesocket response.

=cut

sub new_account {
    my ($self, %args) = @_;
    $args{currency} //= get_new_account_currency($self->client);
    $args{platform} //= $self->name;

    my ($account_type, $market_type, $currency, $dry_run, $landing_company_short) = @{\%args}{qw/account_type market_type currency dry_run company/};
    my $client      = $self->client;
    my $user        = $self->user;
    my $server      = $account_type;
    my $environment = $account_type eq 'real' ? 'live' : 'demo';
    my $user_id     = $self->user->id;
    my $redis       = BOM::Config::Redis::redis_mt5_user_write();

    # Account creation lock to avoid spamming
    my $lock_key      = "account_creation_lock:$user_id";
    my $acquired_lock = $redis->set($lock_key, 1, 'EX', 10, 'NX');
    if (!$acquired_lock) {
        die +{error_code => 'CTraderAccountCreationInProgress'};
    }

    die +{error_code => 'CTraderInvalidAccountType'} unless any { $account_type eq $_ } qw/real demo/;

    $self->server_check($server);

    if (not defined $landing_company_short) {
        $landing_company_short = get_ctrader_landing_company($client);
        die +{error_code => 'CTraderNotAllowed'} unless $landing_company_short;
    } else {
        die +{error_code => 'CTraderNotAllowed'} unless $landing_company_short eq get_ctrader_landing_company($client);
    }

    $self->rule_engine->verify_action('new_trading_account', %args, loginid => $self->client->loginid);

    die +{error_code => 'CTraderInvalidMarketType'} unless $market_type eq 'all';

    my $group = construct_group_name($market_type, $landing_company_short, $currency);

    my $group_config = get_ctrader_account_type($account_type . '_' . $group);

    # Do no allow account creation without ctrader group config
    die +{error_code => 'CTraderNotAllowed'} unless $group_config;

    my $wallet_loginid = $self->client->is_wallet ? $self->client->loginid : undef;
    my @loginids       = $user->get_ctrader_loginids(wallet_loginid => $wallet_loginid);

    my $existing_account = check_existing_account(\@loginids, $user, $group, $account_type);
    die +{
        error_code => $existing_account->{error},
        params     => [$account_type, $existing_account->{params}]} if $existing_account->{error};

    # This is for dry run mode
    return {
        account_type    => $account_type,
        balance         => 0,
        currency        => 'USD',
        display_balance => '0.00'
    } if $dry_run;

    my $new_trader_params = {
        client      => $client,
        currency    => $currency,
        group       => $group,
        environment => $environment,
    };
    $new_trader_params = construct_new_trader_params($new_trader_params);
    die +{error_code => 'CTraderUnsupportedCountry'} unless $new_trader_params->{contactDetails}->{countryId};

    my $available_group = $self->call_api(
        server => $server,
        method => 'ctradermanager_getgrouplist'
    );
    my $valid_group = is_valid_group($new_trader_params->{groupName}, $available_group);
    die +{error_code => 'CTraderInvalidGroup'} unless $valid_group;

    my $trader_account = $self->call_api(
        server  => $server,
        method  => 'trader_create',
        payload => $new_trader_params
    );

    die +{error_code => 'CTraderAccountCreateFailed'} unless $trader_account->{login};

    my $group_id = group_to_groupid($trader_account->{groupName}, $available_group);
    die +{error_code => $group_id->{error}} if ref $group_id eq 'HASH' and $group_id->{error};

    my $trader_lightlist = $self->call_api(
        server  => $server,
        method  => 'tradermanager_gettraderlightlist',
        payload => {
            fromTimestamp => $trader_account->{registrationTimestamp},
            toTimestamp   => $trader_account->{registrationTimestamp},
            groupId       => $group_id,
        });

    my $traderId = traderid_from_traderlightlist($trader_account->{login}, $trader_lightlist);
    die +{error_code => 'CTraderAccountCreateFailed'} unless $traderId;

    my $ctid_userid = $self->get_ctid_userid();
    unless ($ctid_userid) {
        my $ctid;
        try {
            $ctid = $self->call_api(
                server  => $server,
                method  => 'ctid_create',
                path    => 'cid',
                payload => {
                    email => $client->email,
                });
        } catch {
            $ctid = $self->call_api(
                server  => $server,
                method  => 'ctid_getuserid',
                path    => 'cid',
                payload => {
                    email => $client->email,
                });
        }

        $ctid_userid = $ctid->{userId};
        die +{error_code => 'CTIDGetFailed'} unless $ctid_userid;

        my $ctid_insert_check = $self->_add_ctid_userid($ctid_userid);

        die +{error_code => 'CTIDGetFailed'} if ref $ctid_insert_check eq 'HASH' and $ctid_insert_check->{error};
    }

    my $citd_link_resp = $self->call_api(
        server  => $server,
        method  => 'ctid_linktrader',
        path    => 'cid',
        payload => {
            environmentName      => $environment,
            userId               => $ctid_userid,
            traderLogin          => $trader_account->{login},
            traderPasswordHash   => $new_trader_params->{hashedPassword},
            returnAccountDetails => 'true',
        });
    die +{error_code => 'CTraderAccountLinkFailed'} unless $citd_link_resp->{ctidTraderAccountId};

    my $prefix     = $account_type eq 'real' ? 'CTR' : 'CTD';
    my $account_id = $prefix . $trader_account->{login};
    my $attributes = {
        login           => $trader_account->{login},
        trader_id       => $traderId,
        group           => $group,
        market_type     => $market_type,
        landing_company => $landing_company_short,
    };

    $user->add_loginid($account_id, PLATFORM_ID, $account_type, $currency, $attributes, $wallet_loginid);

    if (my $token = $self->client->myaffiliates_token and $args{account_type} ne 'demo') {
        BOM::Platform::Event::Emitter::emit(
            'cms_add_affiliate_client',
            {
                binary_user_id => $self->user->id,
                token          => $token,
                loginid        => $account_id,
                platform       => PLATFORM_ID
            });
    }

    BOM::Platform::Event::Emitter::emit(
        'ctrader_account_created',
        {
            loginid        => $self->client->loginid,
            binary_user_id => $self->user->id,
            ctid_userid    => $ctid_userid,
            account_type   => $account_type
        });

    my $account = {
        local_account   => $user->loginid_details->{$account_id},
        ctrader_account => $trader_account
    };

    # After account creation is complete, release the lock
    $redis->del($lock_key);

    return $self->account_details($account);
}

=head2 get_accounts

Gets all available client accounts and returns list formatted for websocket response.

Takes the following arguments as named parameters:

=over 4

=item * C<type>. Filter accounts to "real" or "demo".

=back

=cut

sub get_accounts {
    my ($self, %args) = @_;

    my @local_accounts = $self->local_accounts(%args) or return [];

    my @result;
    for my $local_account (@local_accounts) {
        next if $args{type} and $args{type} ne $local_account->{account_type};
        my $ct_account;
        try {
            $ct_account = $self->call_api(
                server  => $local_account->{account_type},
                method  => 'trader_get',
                payload => {loginid => $local_account->{attributes}->{login}});
        } catch {
            next;
        }

        my $account = {
            local_account   => $local_account,
            ctrader_account => $ct_account
        };
        push @result, $self->account_details($account);
    }

    return \@result;
}

=head2 get_account_info

The CTrader implementation of getting an account info.

=cut

sub get_account_info {
    my ($self, $loginid) = @_;

    # ignore_wallet_links means this call can return any account belong to user, regardles of wallet links
    my @accounts = $self->get_accounts(ignore_wallet_links => 1)->@*;

    my $account = first { $_->{account_id} eq $loginid } @accounts;

    die "CTraderInvalidAccount\n" unless ($account);

    return $account;
}

=head2 available_accounts

Get list of available ctrader accounts

=cut

sub available_accounts {
    my ($self)                = @_;
    my $landing_company_short = get_ctrader_landing_company($self->client);
    my $lc                    = LandingCompany::Registry->by_name($landing_company_short);

    my @trading_accounts;
    push @trading_accounts,
        +{
        shortcode                  => $lc->short,
        name                       => $lc->name,
        requirements               => $lc->requirements,
        sub_account_type           => 'standard',
        market_type                => 'all',
        linkable_landing_companies => $lc->mt5_require_deriv_account_at,
        }
        if $lc;

    return \@trading_accounts;
}

=head2 account_details

Format account details from API response and local db.

=over 4

=item * C<local_account> Account data from internal DB.

=item * C<ctrader_account> Account data from ctrader API call.

=back

=cut

sub account_details {
    my ($self, $account_data)             = @_;
    my ($local_account, $ctrader_account) = @{$account_data}{qw/local_account ctrader_account/};
    my $currency = $ctrader_account->{depositCurrency};
    my $balance  = $ctrader_account->{balance};

    return {
        login                 => $ctrader_account->{login},
        account_id            => $local_account->{loginid},
        account_type          => $local_account->{account_type},
        balance               => financialrounding('amount', $currency, $balance),
        currency              => $currency,
        display_balance       => formatnumber('amount', $currency, $balance),
        platform              => PLATFORM_ID,
        market_type           => $local_account->{attributes}->{market_type},
        landing_company_short => $local_account->{attributes}->{landing_company},
    };
}

=head2 register_partnerid

Check if client is IB, if so register as cTrader partner

=cut

sub register_partnerid {
    my ($self, $args) = @_;

    $self->call_api(
        server  => $args->{account_type},
        method  => 'ctid_referral',
        path    => 'cid',
        payload => {
            partnerId => $args->{partnerid},
            userId    => $args->{ctid_userid}});

    return 1;
}

=head2 get_ctid_userid

Gets ctid userid by binary_user_id

=cut

sub get_ctid_userid {
    my ($self) = @_;

    my ($user_id) = $self->user->dbic->run(
        fixup => sub {
            $_->selectrow_array("SELECT ctid_user_id FROM ctrader.get_ctrader_userid(?)", undef, $self->user->id);
        });

    return $user_id;
}

=head2 _add_ctid_userid

Add CTID UserID to the binary user and userid mapping table

=cut

sub _add_ctid_userid {
    my ($self, $ctid_userid) = @_;

    try {
        my ($result) = $self->user->dbic->run(
            fixup => sub {
                $_->do('SELECT FROM ctrader.add_ctrader_userid(?, ?)', undef, $self->user->id, $ctid_userid);
            });

        return $result;
    } catch ($e) {
        return {error => 'ErrorAddingCtidUserId'};
    }

}

=head2 http

Returns the current L<HTTP::Tiny> instance or creates a new one if neeeded.

=cut

sub http {
    return shift->{http} //= HTTP::Tiny->new(timeout => HTTP_TIMEOUT);
}

=head2 call_api

Calls API service with given params.

Takes the following named arguments, plus others according to the method.

=over 4

=item * C<server>. (Required) Server such as "real" or "demo"

=item * C<path>. Additional API path, at the current implementation, only "cid" or "trader".

=item * C<method>. (Required) Which API to call, example "trader_get"

=item * C<payload>. Additional data required by its corresponding API method calls. 

=item * C<quiet>. Don't die or log datadog stats when api returns error.

=back

=cut

sub call_api {
    my ($self, %args) = @_;

    $self->server_check($args{server});

    my $config          = BOM::Config::ctrader_proxy_api_config();
    my $ctrader_servers = {
        real => $config->{ctrader_live_proxy_url},
        demo => $config->{ctrader_demo_proxy_url}};

    my $server_url = $ctrader_servers->{$args{server}};
    $server_url .= $args{path} ? $args{path} : 'trader';

    my $quiet   = delete $args{quiet};
    my $headers = {
        'Accept'       => "application/json",
        'Content-Type' => "application/json",
    };
    my $payload = encode_json_utf8(\%args);
    my $resp;
    try {
        my $start_time = [Time::HiRes::gettimeofday];
        $resp = $self->http->post(
            $server_url,
            {
                content => $payload,
                headers => $headers
            });

        if (my $service_timing = $resp->{headers}{timing}) {
            stats_timing(
                'ctrader.rpc_service.timing',
                (1000 * Time::HiRes::tv_interval($start_time)) - $service_timing,
                {tags => ['method:' . $args{method}]});
        }

        $resp->{content} = decode_json_utf8($resp->{content} || '{}');
        die unless $resp->{success} or $quiet;    # we expect some calls to fail, eg. client_get
        return $resp->{content};
    } catch ($e) {
        return $e if ref $e eq 'HASH';
        $self->handle_api_error($resp, undef, %args);
    }
}

1;
