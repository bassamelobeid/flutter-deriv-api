package BOM::TradingPlatform::DXTrader;

use strict;
use warnings;
no indirect;

use Syntax::Keyword::Try;
use YAML::XS;
use HTTP::Tiny;
use JSON::MaybeUTF8        qw(:v1);
use List::Util             qw(first any uniq);
use Array::Utils           qw(array_minus);
use Format::Util::Numbers  qw(financialrounding formatnumber);
use Digest::SHA1           qw(sha1_hex);
use BOM::Platform::Context qw(request);
use BOM::Platform::Event::Emitter;
use BOM::Config;
use Log::Any                   qw($log);
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use BOM::Config::Redis;
use Time::HiRes qw(gettimeofday tv_interval);
use BOM::Database::UserDB;
use Data::Dump 'pp';

=head1 NAME 

BOM::TradingPlatform::DXTrader - The DevExperts trading platform implementation.

=head1 SYNOPSIS 

    my $dx = BOM::TradingPlatform::DXTrader->new(client => $client);
    my $account = $dx->new_account(...);
    $dx->deposit(account => $account, ...);

=head1 DESCRIPTION 

Provides a high level implementation of the DevExperts API.

Exposes DevExperts API through our trading platform interface.

This module must provide support to each DevExperts integration within our systems.

=cut

use parent qw(BOM::TradingPlatform);

use constant {
    DX_CLEARING_CODE           => 'default',
    DX_DOMAIN                  => 'default',
    HTTP_TIMEOUT               => 20,
    DEMO_TOPUP_AMOUNT          => 10000,
    DEMO_TOPUP_MINIMUM_BALANCE => 1000,
    PLATFORM_ID                => 'dxtrade',
    TRADING_CATEGORY_MAP       => {
        financial => 'Financials Only',
        synthetic => 'Synthetics Only',
        gaming    => 'Synthetics Only',
        all       => 'CFD'
    }};

=head2 DEFAULT_CATEGORIES

Provides a list of standard permissions assigned on DerivX account by default

=cut

use constant DEFAULT_CATEGORIES => ({
        category => 'AutoExecution',
        value    => 'Bbook',
    },
    {
        category => 'Commissions',
        value    => 'Zero Commissions',
    },
    {
        category => 'Financing',
        value    => 'Standard Swaps',
    },
    {
        category => 'Limits',
        value    => 'Standard Limits',
    },
    {
        category => 'Margining',
        value    => 'Standard Margining',
    },
    {
        category => 'Spreads',
        value    => 'Standard Spreads',
    },
);

=head2 new

Creates and returns a new L<BOM::TradingPlatform::DXTrader> instance.

Takes the following arguments as named parameters:

=over 4

=item * C<client> (required). Client instance. Must be the client who will perform any operation on the account.

=item * C<rule_engine>. Rule engine instance. Requried for any operation that uses rule engine.

=item * C<user> User instance. Required for any operation that directly/indirectly calls user->loginid_details.

=back

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
    my $suspend = BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend;
    return qw(real demo) if $self->client and any { $self->client->email eq $_ } $suspend->user_exceptions->@*;
    return ()            if $suspend->all;
    my @servers = grep { !$suspend->$_ } qw(real demo);
    return @servers;
}

=head2 account_servers

Returns all servers used by existing dxtrade accounts.

=cut

sub account_servers {
    my ($self) = @_;
    my @servers = uniq(map { $_->{account_type} } $self->local_accounts(ignore_wallet_links => 1));
    return @servers;
}

=head2 server_check

Throw appropriate errors if any @servers are not available.
In some cases we need to call this before calling the api, e.g. deposit.

=cut

sub server_check {
    my ($self, @servers) = @_;

    my @active_servers = $self->active_servers;
    if (array_minus(@servers, @active_servers)) {
        die +{error_code => 'DXSuspended'} if BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all;
        die +{error_code => 'DXServerSuspended'};
    }
}

=head2 check_trading_category

Checks if trading category matches

=cut

sub check_trading_category {
    my ($self, $market_type, $account_trading_category) = @_;
    my $trading_category   = TRADING_CATEGORY_MAP->{$market_type};
    my @trading_categories = ('Financials Only', 'Synthetics Only', 'CFD');

    #
    return grep { $_ eq $account_trading_category } @trading_categories if $market_type eq 'all';

    return $account_trading_category eq $trading_category;
}

=head2 local_accounts

Returns dxtrade account info from our db.

Takes the following named parameters:

=over 4

=item * C<ignore_wallet_links> if true, any wallet links will be ignored.

=back

=cut

sub local_accounts {
    my ($self, %args) = @_;

    my %loginid_details = $self->user->loginid_details->%*;
    my @accounts        = sort grep { ($_->{platform} // '') eq PLATFORM_ID && !$_->{status} } values %loginid_details;
    @accounts =
        grep { $_->{wallet_loginid} ? $self->client->is_wallet && $self->client->loginid eq $_->{wallet_loginid} : !$self->client->is_wallet }
        @accounts
        unless $args{ignore_wallet_links};
    return @accounts;
}

=head1 RPC methods

=head2 new_account

Creates a new DXTrader account with a client if necessary.

Takes the following arguments as named parameters:

=over 4

=item * C<type> (required). "real" or "demo".

=item * C<currency>. Client's currency will be used if not provided.

=item * C<password> (required).

=back

Returns new account fields formatted for wesocket response.

=cut

sub new_account {
    my ($self, %args) = @_;

    # Currency validated by rules engine, if not given take it from LC default
    $args{currency} //= $self->get_new_account_currency();
    $args{platform} //= $self->name;
    $args{wallet_loginid} = $self->client->is_wallet ? $self->client->loginid : undef;

    $self->rule_engine->verify_action('new_trading_account', %args, loginid => $self->client->loginid);

    my $server = $args{account_type};    # account_type means a different thing for dxtrade

    die +{
        error_code => 'DXInvalidMarketType',
        params     => [$server]}
        unless $self->is_valid_market_type($server, $args{market_type});

    my $account_type     = $args{account_type} eq 'real' ? 'LIVE' : 'DEMO';
    my $trading_category = TRADING_CATEGORY_MAP->{$args{market_type}};

    my $currency = $args{currency};
    my $password = $args{password} or die 'password required';

    my $dxclient = $self->dxclient_get($server) || $self->dxclient_create($server, $password);

    my ($account, $err) = $self->find_account({
        dxclient     => $dxclient,
        currency     => $currency,
        account_type => $account_type,
        market_type  => $args{market_type},
    });

    if ($account && $err && $err eq 'ORPHAN_ACCOUNT') {
        return $self->save_account({
            dxclient     => $dxclient,
            account      => $account,
            market_type  => $args{market_type},
            account_type => $args{account_type},
            account_id   => $account->{account_code},
        });
    } elsif ($account) {
        die +{
            error_code     => 'DXExistingAccount',
            message_params => [$account->{account_code}]};
    } elsif ($err && $err ne 'NOT_FOUND') {
        die "Unxpected output of find_account funtion <$err> for client " . $self->client->loginid;
    }

    my ($seq_num) = $self->user->dbic->run(
        ping => sub {
            $_->selectrow_array("SELECT nextval('users.devexperts_account_id')");
        });

    $seq_num += $self->config->{real_account_ids_offset} // 0;

    my $prefix = $args{account_type} eq 'real' ? 'DXR' : 'DXD';
    my $account_code =
        $self->config->{real_account_ids} ? $prefix . $seq_num : $prefix . $self->unique_id;    # dx account id, must be unique in their system
    my $account_id   = $prefix . $seq_num;                                                      # our loginid
    my $balance      = $args{account_type} eq 'demo' ? DEMO_TOPUP_AMOUNT : 0;
    my $account_resp = $self->call_api(
        server        => $server,
        method        => 'client_account_create',
        login         => $dxclient->{login},
        domain        => $dxclient->{domain},
        account_code  => $account_code,
        clearing_code => DX_CLEARING_CODE,
        account_type  => $account_type,
        currency      => $currency,
        balance       => $balance,
        categories    => [{
                category => 'Trading',
                value    => $trading_category,
            },
            DEFAULT_CATEGORIES,
        ],
    );

    # Verifying here if the account has been created
    try {
        $self->call_api(
            server => $server,
            login  => $dxclient->{login},
            domain => $dxclient->{domain},
            method => 'client_get',
        );
    } catch {
        die +{error_code => 'DXNewAccountFailed'};
    }

    $account = $account_resp->{content};

    return $self->save_account({
        dxclient     => $dxclient,
        account      => $account,
        market_type  => $args{market_type},
        account_type => $args{account_type},
        account_id   => $account_id,
    });
}

=head2 save_account

Saves provided account into UserDB
If account has affiliate token it'll emit event to link this account latter

=cut

sub save_account {
    my ($self, $args) = @_;
    my ($dxclient, $account, $market_type, $account_type, $account_id) = $args->@{qw(dxclient account market_type account_type account_id)};

    my %attributes = (
        login         => $dxclient->{login},
        market_type   => $market_type,
        client_domain => $dxclient->{domain},
        account_code  => $account->{account_code},
        clearing_code => $account->{clearing_code},
    );

    my $wallet = $self->client->is_wallet ? $self->client->loginid : undef;

    $self->user->add_loginid($account_id, PLATFORM_ID, $account_type, $account->{currency}, \%attributes, $wallet);

    # If client has affiliate token, link the client to the affiliate.
    if (my $token = $self->client->myaffiliates_token and $account_type ne 'demo') {
        BOM::Platform::Event::Emitter::emit(
            'cms_add_affiliate_client',
            {
                binary_user_id => $self->client->binary_user_id,
                token          => $token,
                loginid        => $account_id,
                platform       => PLATFORM_ID
            });
    }

    $account->{account_id} = $account_id;
    $account->{login}      = $dxclient->{login};

    return $self->account_details($account);
}

=head2 find_account

Search in dxclient object for account with specified conditions:
currency, account_type, market_type.
if wallet argument is provided, it'll look only for accounts connected to the same wallet. 

=cut

sub find_account {
    my ($self, $args) = @_;

    my ($dxclient, $currency, $account_type, $market_type) = $args->@{qw(dxclient currency account_type market_type)};

    my $accounts_links;
    my $loginid_details = $self->user->loginid_details;

    my $wallet = $self->client->is_wallet ? $self->client->loginid : undef;

    for my $account (($dxclient->{accounts} // [])->@*) {
        next unless $account->{currency} eq $currency;
        next unless $account->{account_type} eq $account_type;
        next unless $account->{type} eq 'CLIENT';
        next unless $account->{status} eq 'FULL_TRADING';        # skip if client not active

        # skip if account has different market type
        next
            unless any { $self->check_trading_category($market_type, $_->{value}) }
            grep { $_->{category} eq 'Trading' } ($account->{categories} // [])->@*;

        my $account_id = $account->{account_code};

        # Found account which is created but not linked yet.
        # Could happen because we lost connection and didn't get response from dxtrader
        # or if we fail to insert to user db
        return $account, 'ORPHAN_ACCOUNT' unless $loginid_details->{$account_id};

        # New wallet flow
        if ($wallet) {
            $accounts_links //= $self->user->get_accounts_links;

            die "Inconsistent data: Orphant trading account" unless $accounts_links->{$account_id};

            # we only intrested in account connected to the same wallet
            next unless $accounts_links->{$account_id}[0]{loginid} eq $wallet;
        }

        return $account, undef;
    }

    return undef, 'NOT_FOUND';
}

=head2 is_valid_market_type

Checks if market type input is valid based on app config

=cut

sub is_valid_market_type {

    my ($self, $server, $market_type) = @_;

    return 1 if ($market_type or $market_type eq 'all');

    return 0;

}

=head2 get_new_account_currency

Resolves the default currency for the account based on Landing Company.

=cut

sub get_new_account_currency {
    my ($self)               = @_;
    my $client               = $self->client;
    my $available_currencies = $client->landing_company->available_trading_platform_currency_group->{dxtrade} // [];
    my ($default_currency)   = $available_currencies->@*;
    return $default_currency;
}

=head2 get_accounts

Gets all available client accounts and returns list formatted for websocket response.

Takes the following arguments as named parameters:

=over 4

=item * C<force>. If true, an error will be raised if any accounts are inaccessible.

=item * C<type>. Filter accounts to real or demo.

=back

=cut

sub get_accounts {
    my ($self, %args) = @_;

    my @local_accounts  = $self->local_accounts(%args) or return [];
    my @account_servers = $self->account_servers;

    my @accounts;
    for my $server (@account_servers) {
        next unless BOM::Config::Runtime->instance->app_config->system->dxtrade->token_authentication->$server;
        next unless any { $server eq $_ } $self->active_servers;
        next if $args{type} and $args{type} ne $server;
        try {
            my $dxclient = $self->dxclient_get($server);
            push @accounts, ($dxclient->{accounts} // [])->@*;
        } catch ($e) {
            die $e if $args{force};
        }
    }

    my @result;
    for my $local_account (@local_accounts) {
        next if $args{type} and $args{type} ne $local_account->{account_type};
        my $account;
        $account->{account_id} = $local_account->{loginid};
        $account->{login}      = $local_account->{attributes}{login};

        if (my $dxaccount = first { $_->{account_code} eq $local_account->{attributes}{account_code} } @accounts) {
            $account->{enabled} = 1;
            $account = {%$account, %$dxaccount};
            push @result, $self->account_details($account);
        } else {
            $account->{account_type} = $local_account->{account_type};
            $account->{enabled}      = 0;
            $account->{market_type}  = $local_account->{attributes}{market_type};
            $account->{currency}     = $local_account->{currency};
            push @result, $self->account_details($account);
        }
    }

    return \@result;
}

=head2 change_password

Changes the password of the client in DevExperts.

Takes the following arguments as named parameters:

=over 4

=item * C<password> (required). the new password.

=back

Returns a hashref of loginids, or dies with error.

=cut

sub change_password {
    my ($self, %args) = @_;

    my $password = $args{password};

    if ($self->local_accounts) {
        $self->server_check($self->account_servers);
    } else {
        $self->user->update_dx_trading_password($password);
        return undef;
    }

    my $pwd_changed;

    for my $server ($self->account_servers) {
        my $dxclient;
        try {
            $dxclient = $self->dxclient_get($server) or next;

            $self->call_api(
                server   => $server,
                method   => 'client_update',
                login    => $dxclient->{login},
                domain   => $dxclient->{domain},
                password => $password,
            );
            $pwd_changed = 1;
        } catch {
            return {failed_logins => [$self->dxtrade_login]};
        }

        try {
            $self->call_api(
                server => $server,
                method => 'logout_user_by_login',
                login  => $dxclient->{login},
                domain => $dxclient->{domain},
            );
        } catch {
            warn 'Failed to logout Deriv X login ' . $dxclient->{login} . ' for ' . $self->client->loginid;
        }
    }

    if ($pwd_changed) {
        $self->user->update_dx_trading_password($password);
    }

    return ($pwd_changed ? {successful_logins => [$self->dxtrade_login]} : undef);
}

=head2 deposit

Transfer from our system to dxtrade.

Takes the following arguments as named parameters:

=over 4

=item * C<amount> in deriv account currency.

=item * C<currency> amount currency.

=item * C<to_account>. Our dxtrade account id.

=back

Returns transaction id in hashref.

=cut

sub deposit {
    my ($self, %args) = @_;

    my $account = first { $_->{loginid} eq $args{to_account} } $self->local_accounts
        or die +{error_code => 'DXInvalidAccount'};

    return $self->demo_top_up($account) if $account->{is_virtual} && !$account->{wallet_loginid};
    $self->server_check($account->{account_type});    # try to avoid debiting deriv if server is not available

    # Sequence:
    # 1. Validation
    # 2. Withdrawal from deriv
    # 3. Deposit to dxtrade

    my $tx_amounts = $self->validate_transfer(
        action               => 'deposit',
        amount               => $args{amount},
        amount_currency      => $self->client->currency,
        platform_currency    => $account->{currency},
        request_currency     => $args{currency},                                             # param is renamed here
        account_type         => $account->{account_type},
        payment_type         => 'dxtrade_transfer',
        landing_company_from => $self->client->landing_company->short,
        landing_company_to   => $self->account_details($account)->{landing_company_short},
        from_account         => $self->client->loginid,
        to_account           => $args{to_account},
    );

    my %txn_details = (
        dxtrade_account_id        => $args{to_account},
        fees                      => $tx_amounts->{fees},
        fees_percent              => $tx_amounts->{fees_percent},
        fees_currency             => $self->client->account->currency_code,     # sending account
        min_fee                   => $tx_amounts->{min_fee},
        fee_calculated_by_percent => $tx_amounts->{fee_calculated_by_percent});

    my $remark = sprintf('Transfer from %s to dxtrade account %s', $self->client->loginid, $args{to_account});

    my $txn;
    try {
        $txn = $self->client_payment(
            payment_type => 'dxtrade_transfer',
            amount       => -$args{amount},        # negative!
            fees         => $tx_amounts->{fees},
            remark       => $remark,
            txn_details  => \%txn_details,
        );

        $self->insert_payment_details($txn->payment_id, $args{to_account}, $tx_amounts->{recv_amount});

        $self->user->daily_transfer_incr(
            amount          => $args{amount},
            amount_currency => $self->client->currency,
            loginid_from    => $self->client->loginid,
            loginid_to      => $args{to_account},
        );
    } catch {
        die +{error_code => 'DXDepositFailed'};
    }

    try {
        $self->call_api(
            server        => $account->{account_type},
            method        => 'account_deposit',
            account_code  => $account->{attributes}{account_code},
            clearing_code => $account->{attributes}{clearing_code},
            id            => $self->unique_id,                                      # must be unique for deposits on this login
            amount        => $tx_amounts->{recv_amount},
            currency      => $account->{currency},
            description   => $self->client->loginid . '#' . $txn->transaction_id,
        );
    } catch {
        die +{error_code => 'DXDepositIncomplete'};
    }

    # get updated balance
    my $update;
    try {
        $update = $self->call_api(
            server        => $account->{account_type},
            method        => 'account_get',
            account_code  => $account->{attributes}{account_code},
            clearing_code => $account->{attributes}{clearing_code},
        );
    } catch {
        die +{error_code => 'DXTransferCompleteError'};
    }

    return {
        $self->account_details($update->{content})->%*,
        transaction_id => $txn->id,
        account_id     => $args{to_account},
        login          => $account->{attributes}{login},
    };
}

=head2 withdraw

Transfer from dxtrade to our system.

Takes the following arguments as named parameters:

=over 4

=item * C<amount> in dxtrade account currency.

=item * C<from_account>. Our dxtrade account id.

=back

Returns transaction id in hashref.

=cut

sub withdraw {
    my ($self, %args) = @_;

    my $account = first { $_->{loginid} eq $args{from_account} } $self->local_accounts
        or die +{error_code => 'DXInvalidAccount'};

    my $server = $account->{account_type};

    # Sequence:
    # 1. Validation
    # 2. Withdraw from dxtrade
    # 3. Deposit to deriv

    my $tx_amounts = $self->validate_transfer(
        action               => 'withdrawal',
        amount               => $args{amount},
        amount_currency      => $account->{currency},
        platform_currency    => $account->{currency},
        request_currency     => $args{currency},                                             # param is renamed here
        account_type         => $account->{account_type},
        landing_company_from => $self->account_details($account)->{landing_company_short},
        landing_company_to   => $self->client->landing_company->short,
        from_account         => $args{from_account},
        to_account           => $self->client->loginid,
    );

    my %call_args = (
        server        => $server,
        method        => 'account_withdrawal',
        account_code  => $account->{attributes}{account_code},
        clearing_code => $account->{attributes}{clearing_code},
        id            => $self->unique_id,                                     # must be unique for withdrawals on this login
        amount        => $args{amount},
        currency      => $account->{currency},
        description   => $args{from_account} . '_' . $self->client->loginid,
    );

    my $resp = $self->call_api(%call_args, quiet => 1);

    die +{error_code => 'DXInsufficientBalance'}
        if $resp->{content}{error_code}
        and $resp->{content}{error_code} eq '30005'
        and $resp->{status} eq '422';

    unless ($resp->{success}) {
        $self->handle_api_error($resp, 'DXWithdrawalFailed', %call_args);
    }

    my %txn_details = (
        dxtrade_account_id        => $args{from_account},
        fees                      => $tx_amounts->{fees},
        fees_percent              => $tx_amounts->{fees_percent},
        fees_currency             => $account->{currency},                      # sending account
        min_fee                   => $tx_amounts->{min_fee},
        fee_calculated_by_percent => $tx_amounts->{fee_calculated_by_percent});

    my $remark = sprintf('Transfer from dxtrade account %s to %s', $args{from_account}, $self->client->loginid);

    my $txn;
    try {
        $txn = $self->client_payment(
            payment_type => 'dxtrade_transfer',
            amount       => $tx_amounts->{recv_amount},
            fees         => $tx_amounts->{fees_in_client_currency},
            remark       => $remark,
            txn_details  => \%txn_details,
        );

        $self->insert_payment_details($txn->payment_id, $args{from_account}, $args{amount} * -1);

        $self->user->daily_transfer_incr(
            amount          => $args{amount},
            amount_currency => $account->{currency},
            loginid_from    => $args{from_account},
            loginid_to      => $self->client->loginid,
        );
    } catch {
        die +{error_code => 'DXWithdrawalIncomplete'};
    }

    # get updated balance
    my $update;
    try {
        $update = $self->call_api(
            server        => $server,
            method        => 'account_get',
            account_code  => $account->{attributes}{account_code},
            clearing_code => $account->{attributes}{clearing_code},
        );
    } catch {
        die +{error_code => 'DXTransferCompleteError'};
    }

    return {
        $self->account_details($update->{content})->%*,
        transaction_id => $txn->id,
        account_id     => $args{from_account},
        login          => $account->{attributes}{login},
    };
}

=head2 demo_top_up

Top up demo account.

=cut

sub demo_top_up {
    my ($self, $account) = @_;

    my $check = $self->call_api(
        server        => $account->{account_type},
        method        => 'account_get',
        account_code  => $account->{attributes}{account_code},
        clearing_code => $account->{attributes}{clearing_code},
    );

    die +{
        error_code => 'DXDemoTopupBalance',
        params     => [formatnumber('amount', 'USD', DEMO_TOPUP_MINIMUM_BALANCE), 'USD']}
        unless $check->{content}{balance} <= DEMO_TOPUP_MINIMUM_BALANCE;

    try {
        $self->call_api(
            server        => $account->{account_type},
            method        => 'account_deposit',
            account_code  => $account->{attributes}{account_code},
            clearing_code => $account->{attributes}{clearing_code},
            id            => $self->unique_id,                        # must be unique for deposits on this login
            amount        => DEMO_TOPUP_AMOUNT,
            currency      => $account->{currency},
        );
    } catch {
        die +{error_code => 'DXDemoTopFailed'};
    }

    return;
}

=head2 check_password

The DXTrader implementation of checking password.

=cut

sub check_password {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 reset_password

The DXTrader implementation of resetting password.

=cut

sub reset_password {
    my ($self, $user_id) = @_;

    my $pwd_reset;

    for my $server ($self->account_servers) {
        my $dxclient;
        try {
            $dxclient = $self->dxclient_get($server) or next;

            $self->call_api(
                server   => $server,
                method   => 'client_update',
                login    => $dxclient->{login},
                domain   => $dxclient->{domain},
                password => undef,
            );
            $pwd_reset = 1;
        } catch {
            return {failed_logins => [$self->dxtrade_login]};
        }
    }

    my $user_db = BOM::Database::UserDB::rose_db();

    $user_db->dbic->run(
        fixup => sub {
            $_->do('SELECT users.reset_dx_trading_password(?)', undef, $user_id);
        });

    return ($pwd_reset ? {successful_logins => [$self->dxtrade_login]} : undef);
}

=head2 get_account_info

The DXTrader implementation of getting an account info.

=cut

sub get_account_info {
    my ($self, $loginid) = @_;

    # ignore_wallet_links means this call can return any DX account belong to user, regardles of wallet links
    my @accounts = $self->get_accounts(ignore_wallet_links => 1)->@*;

    my $account = first { $_->{account_id} eq $loginid } @accounts;

    die "DXInvalidAccount\n" unless ($account);

    return $account;
}

=head2 generate_login_token

Generate a temporary login token for a server.

=cut

sub generate_login_token {
    my ($self, $server) = @_;

    die +{error_code => 'DXNoServer'}  unless $server;
    die +{error_code => 'DXNoAccount'} unless any { $server eq $_ } $self->account_servers;
    $self->server_check($server);

    my $resp = $self->call_api(
        server => $server,
        method => 'generate_token',
        login  => $self->dxtrade_login,
        domain => DX_DOMAIN,
    );

    die +{error_code => 'DXTokenGenerationFailed'} unless $resp->{success};
    return $resp->{content};
}

=head2 get_open_positions

The DXTrader implementation of getting an account open positions

=cut

sub get_open_positions {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head1 Non-RPC methods

=head2 config

Generates and caches configuration.

=cut

sub config {
    my $self = shift;
    return $self->{config} //= do {
        my $config = YAML::XS::LoadFile('/etc/rmg/devexperts.yml');
        if ($ENV{DEVEXPERTS_API_SERVICE_PORT}) {
            # running under tests
            $config->{dxweb_service_url} = 'http://localhost:' . $ENV{DEVEXPERTS_API_SERVICE_PORT};
        } else {
            $config->{dxweb_service_url} = $config->{dxweb_service}{host} // 'http://localhost';
            $config->{dxweb_service_url} .= ':' . $config->{dxweb_service}{port} if $config->{dxweb_service}{port};
        }
        $config;
    }
}

=head2 call_api

Calls API service with given params.

Takes the following named arguments, plus others according to the method.

=over 4

=item * C<method>. Required.

=item * C<server>. Required.

=item * C<quiet>. Don't die or log datadog stats when api returns error.

=back

=cut

sub call_api {
    my ($self, %args) = @_;

    $self->server_check($args{server});

    my $server    = $args{server};
    my $auth_type = BOM::Config::Runtime->instance->app_config->system->dxtrade->token_authentication->$server;

    $args{token_auth} = $auth_type;

    my $quiet   = delete $args{quiet};
    my $payload = encode_json_utf8(\%args);
    my $resp;

    try {
        my $start_time = [Time::HiRes::gettimeofday];
        $resp = $self->http->post($self->config->{dxweb_service_url}, {content => $payload});

        if (my $service_timing = $resp->{headers}{timing}) {
            stats_timing(
                'devexperts.rpc_service.timing',
                (1000 * Time::HiRes::tv_interval($start_time)) - $service_timing,
                {tags => ['server:' . $args{server}, 'method:' . $args{method}]});
        }

        $resp->{content} = decode_json_utf8($resp->{content} || '{}')
            if ($resp->{headers}{'content-type'} // '') eq 'application/javascript';
        die unless $resp->{success} or $quiet;    # we expect some calls to fail, eg. client_get
        return $resp;
    } catch ($e) {
        $self->handle_api_error($resp, undef, %args);
    }
}

=head2 handle_api_error

Called when an unexpcted Devexperts API error occurs. Dies with generic error code unless one is provided.

=cut

sub handle_api_error {
    my ($self, $resp, $error_code, %args) = @_;

    $args{password} = '<hidden>'                            if $args{password};
    $resp           = [$resp->@{qw/content reason status/}] if ref $resp;
    stats_inc('devexperts.rpc_service.api_call_fail', {tags => ['server:' . $args{server}, 'method:' . $args{method}]});
    $log->warnf('devexperts call failed for %s: %s, call args: %s', $self->client->loginid, $resp, \%args);
    die +{error_code => $error_code // 'DXGeneral'};
}

=head2 http

Returns the current L<HTTP::Tiny> instance or creates a new one if neeeded.

=cut

sub http {
    return shift->{http} //= HTTP::Tiny->new(timeout => HTTP_TIMEOUT);
}

=head2 dxclient_get

Gets the devexperts client information of $self->client, if it exists.

=cut

sub dxclient_get {
    my ($self, $server) = @_;

    my $login = $self->dxtrade_login;

    my %args = (
        server => $server,
        method => 'client_get',
        login  => $login,
        domain => DX_DOMAIN,
    );

    my $resp = $self->call_api(%args, quiet => 1);

    return $resp->{content} if $resp->{success};

    # expected response for not found
    return undef if ($resp->{status} eq '404' and ref $resp->{content} eq 'HASH' and ($resp->{content}{error_code} // '') eq '30002');

    $self->handle_api_error($resp, undef, %args);
}

=head2 dxclient_create

Create new dxclient via DxTrade api

=cut

sub dxclient_create {
    my ($self, $server, $password) = @_;

    my $login       = $self->dxtrade_login;
    my $client_resp = $self->call_api(
        server   => $server,
        method   => 'client_create',
        domain   => DX_DOMAIN,
        login    => $login,
        password => $password,
    );

    my $dxclient = $client_resp->{content};
    die 'Created client does not have requested login' unless $dxclient->{login} eq $login;

    return $dxclient;
}

=head2 dxtrade_login

Gets the common login id for dxtrade. The same login is used for all accounts.

=cut

sub dxtrade_login {
    my $self = shift;

    if ($self->config->{real_account_ids}) {
        my $prefix = $self->config->{real_account_ids_login_prefix} // '';
        return $prefix . $self->user->id;
    } else {
        my $account = first { ($_->{platform} // '') eq PLATFORM_ID } values $self->user->loginid_details->%*;
        return $account->{attributes}{login} if $account;
        return sha1_hex($$ . time . rand);
    }
}

=head2 _get_market_type

Gets the market type given the DerivX Trading Category

=cut

sub _get_market_type {
    my ($self, $trading_category) = @_;
    my ($market_type) = grep { TRADING_CATEGORY_MAP->{$_} eq $trading_category } keys TRADING_CATEGORY_MAP->%*;
    return 'synthetic' if $market_type eq 'gaming';
    return $market_type;
}

=head2 account_details

Format account details for websocket response.

=cut

sub account_details {
    my ($self, $account) = @_;

    my $category    = {};
    my $market_type = '';
    if (exists($account->{categories})) {
        $category    = first { $_->{category} eq 'Trading' } $account->{categories}->@*;
        $market_type = $self->_get_market_type($category->{value});
    }
    $market_type             = $account->{market_type} if !exists($category->{value});
    $account->{account_type} = ($account->{account_type} eq 'LIVE' ? 'real' : 'demo') unless any { $account->{account_type} eq $_ } qw(real demo);
    $account->{enabled}      = 1 if !exists($account->{enabled});

    return {
        login        => $account->{login},
        account_id   => $account->{account_id},
        account_type => $account->{account_type},
        enabled      => $account->{enabled},
        $account->{enabled} ? (balance => financialrounding('amount', $account->{currency}, $account->{balance})) : (),
        currency => $account->{currency},
        $account->{enabled} ? (display_balance => formatnumber('amount', $account->{currency}, $account->{balance})) : (),
        platform              => PLATFORM_ID,
        market_type           => $market_type,
        landing_company_short => 'svg',          #todo
    };
}

=head2 unique_id

Generates a 40 character unique id.

=cut

sub unique_id {
    return sha1_hex($$ . time . rand);
}

=head2 validate_payment

Platform specific payment validation. Generic validation is performed by parent class method.

Takes the following arguments as named parameters:

=over 4

=item * C<action>: deposit or withdrawal.

=item * C<amount>: amount to be sent from source account.

=item * C<currency>: currency of trading platform account.

=item * C<account_type>: type of trading account, demo or real.

=back

Returns result of parent class method.

=cut

sub validate_payment {
    my ($self, %params) = @_;
    # dx specific validations to go here
    return $self->SUPER::validate_payment(%params);
}

=head2 insert_payment_details

Inserts transfer details to the payment.dxtrade_transfer table.
This assists reporting to know which dxtrade account was involved.

Takes the following arguments:

=over 4

=item * C<$payment_id>.

=item * C<$account_id>: dxtrade account id.

=item * C<$amount>: amount credited/debited to dxtrade account.

=back

=cut

sub insert_payment_details {
    my ($self, $payment_id, $account_id, $amount) = @_;

    my ($seq_num) = $self->client->db->dbic->run(
        ping => sub {
            $_->do('INSERT INTO payment.dxtrade_transfer (payment_id, dxtrade_account_id, dxtrade_amount) VALUES (?,?,?)',
                undef, $payment_id, $account_id, $amount);
        });
}

=head2 archive_dx_account

Sets the status to 'TERMINATED' in DerivX and changes the
'status' field in users.loginid table to 'archived'

Takes the following arguments:

=over 4

=item * C<$account_type>: dxtrade account type

=item * C<$financial_account>: account code of the financial account

=back

=cut

sub archive_dx_account {
    my ($self, $account_type, $financial_account) = @_;

    $self->call_api(
        server        => $account_type,
        method        => 'account_update',
        clearing_code => DX_CLEARING_CODE,
        account_code  => $financial_account,
        status        => 'TERMINATED'
    );

    my $user_db = BOM::Database::UserDB::rose_db();

    $user_db->dbic->run(
        fixup => sub {
            $_->do(
                "UPDATE users.loginid 
                    SET status = 'archived' 
                    WHERE loginid = ?",
                undef,
                $financial_account
            );
        });
}

=head2 update_details

Updates the 'market_type' attribute to 'all' and sets 'Trading' 
category to 'CFD'

Takes the following arguments:

=over 4

=item * C<$synthetic_account>: account code of the synthetic account

=back

=cut

sub update_details {
    my ($self, $account_type, $synthetic_account) = @_;

    $self->call_api(
        server        => $account_type,
        method        => 'account_category_set',
        clearing_code => DX_CLEARING_CODE,
        account_code  => $synthetic_account,
        category_code => "Trading",
        value         => "CFD",
    );

    my $user_db = BOM::Database::UserDB::rose_db();

    $user_db->dbic->run(
        fixup => sub {
            $_->do(
                "UPDATE users.loginid 
                    SET attributes = jsonb_set(attributes, '{market_type}', '\"all\"') 
                    WHERE loginid = ?",
                undef,
                $synthetic_account
            );
        });
}

1;
