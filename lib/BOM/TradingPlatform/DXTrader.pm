package BOM::TradingPlatform::DXTrader;

use strict;
use warnings;
no indirect;

use Syntax::Keyword::Try;
use YAML::XS;
use HTTP::Tiny;
use JSON::MaybeUTF8 qw(:v1);
use List::Util qw(first any);
use Format::Util::Numbers qw(financialrounding formatnumber);
use Digest::SHA1 qw(sha1_hex);
use BOM::Platform::Context qw(request);
use BOM::Rules::Engine;

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
    HTTP_TIMEOUT               => 10,
    DEMO_TOPUP_AMOUNT          => 10000,
    DEMO_TOPUP_MINIMUM_BALANCE => 1000,
};

=head2 new

Creates and returns a new L<BOM::TradingPlatform::DXTrader> instance.

=cut

sub new {
    my ($class, %args) = @_;
    die +{error_code => 'DXSuspended'}
        if BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all
        and $args{client}
        and $args{client}->user->dxtrade_loginids;
    return bless {client => $args{client}}, $class;
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

    my $rule_engine = BOM::Rules::Engine->new(client => $self->client);
    $rule_engine->verify_action('new_trading_account', \%args);

    my $server           = $args{account_type};    # account_type means a different thing for dxtrade
    my $account_type     = $args{account_type} eq 'real'     ? 'LIVE'            : 'DEMO';
    my $trading_category = $args{market_type} eq 'financial' ? 'Financials Only' : 'Synthetics Only';

    my $currency = $args{currency};

    my $password = $args{password};
    if (BOM::Config::Runtime->instance->app_config->system->suspend->universal_password) {
        die 'password required' unless $password;
    } else {
        $password = $self->client->user->password;
    }

    my $dxclient = $self->dxclient_get($server);

    if ($dxclient) {
        my $existing = first {
                    $_->{currency} eq $currency
                and $_->{account_type} eq $account_type
                and $_->{type} eq 'CLIENT'
                and $_->{status} eq 'FULL_TRADING'
                and any { $_->{category} eq 'Trading' and $_->{value} eq $trading_category }
            ($_->{categories} // [])->@*
        }
        ($dxclient->{accounts} // [])->@*;
        die +{
            error_code     => 'DXExistingAccount',
            message_params => [$existing->{account_code}]} if $existing;

    } else {
        # no existing client, try to create one
        die 'password required' unless $password;
        my $login       = $self->dxtrade_login;
        my $client_resp = $self->call_api(
            $server,
            'client_create',
            domain   => DX_DOMAIN,
            login    => $login,
            password => $password,
        );
        die 'Failed to create DevExperts client' unless $client_resp->{success};
        $dxclient = $client_resp->{content};
        die 'Created client does not have requested login' unless $dxclient->{login} eq $login;
    }

    my ($seq_num) = $self->client->user->dbic->run(
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
        $server,
        'client_account_create',
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
            {
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
        ],
    );

    die 'Failed to create DevExperts account' unless exists $account_resp->{success};
    my $account = $account_resp->{content};
    die 'Created account does not have requested account code' unless $account->{account_code} eq $account_code;

    my %attributes = (
        login         => $dxclient->{login},
        market_type   => $args{market_type},
        client_domain => $dxclient->{domain},
        account_code  => $account->{account_code},
        clearing_code => $account->{clearing_code},
    );

    $self->client->user->add_loginid($account_id, 'dxtrade', $args{account_type}, $account->{currency}, \%attributes);

    $account->{account_id} = $account_id;
    $account->{login}      = $dxclient->{login};

    return $self->account_details($account);
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

Gets all client accounts and returns list formatted for websocket response.

=cut

sub get_accounts {
    my ($self) = @_;

    my @accounts;
    for my $server ('demo', 'real') {
        my $dxclient = $self->dxclient_get($server);
        push @accounts, ($dxclient->{accounts} // [])->@*;
    }
    return [] unless @accounts;

    my $logins = $self->client->user->loginid_details;
    my @result;

    for my $login (sort keys %$logins) {
        next unless ($logins->{$login}{platform} // '') eq 'dxtrade';
        if (my $account = first { $_->{account_code} eq $logins->{$login}{attributes}{account_code} } @accounts) {
            $account->{account_id} = $login;
            $account->{login}      = $logins->{$login}{attributes}{login};
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

Returns future or dies with error.

=cut

sub change_password {
    my ($self, %args) = @_;

    my $password = $args{password} or die +{error_code => 'PasswordRequired'};
    my $pwd_changed;

    for my $server ('demo', 'real') {
        my $dxclient;
        try {
            $dxclient = $self->dxclient_get($server) or next;

            my $resp = $self->call_api(
                $server,
                'client_update',
                login    => $dxclient->{login},
                domain   => $dxclient->{domain},
                password => $password,
            );
            die unless $resp->{success};
            $pwd_changed = 1;
        } catch {
            return Future->done({failed_dx_logins => [$self->dxtrade_login]});
        }

        try {
            $self->call_api(
                $server,
                'logout_user_by_login',
                login  => $dxclient->{login},
                domain => $dxclient->{domain},
            );
        } catch {
            warn 'Failed to logout Deriv X login ' . $dxclient->{login} . ' for ' . $self->client->loginid;
        }
    }

    return Future->done($pwd_changed ? {successful_dx_logins => [$self->dxtrade_login]} : undef);
}

=head2 deposit

Transfer from our system to dxtrade.

Takes the following arguments as named parameters:

=over 4

=item * C<amount> in deriv account currency.

=item * C<to_account>. Our dxtrade account id.

=back

Returns transaction id in hashref.

=cut

sub deposit {
    my ($self, %args) = @_;

    my $account = $self->client->user->loginid_details->{$args{to_account}}
        or die +{error_code => 'DXInvalidAccount'};

    return $self->demo_top_up($account) if $account->{account_type} eq 'demo';

    # Sequence:
    # 1. Validation
    # 2. Withdrawal from deriv
    # 3. Deposit to dxtrade

    my $tx_amounts = $self->validate_transfer(
        action            => 'deposit',
        amount            => $args{amount},
        platform_currency => $account->{currency},
        account_type      => $account->{account_type},
        currency          => $args{currency},
    );

    my %txn_details = (
        dxtrade_account_id        => $args{to_account},
        fees                      => $tx_amounts->{fees},
        fees_percent              => $tx_amounts->{fees_percent},
        fees_currency             => $self->client->account->currency_code,     # sending account
        min_fee                   => $tx_amounts->{min_fee},
        fee_calculated_by_percent => $tx_amounts->{fee_calculated_by_percent});

    my $remark = sprintf(
        'Transfer from %s to dxtrade account %s (account id %s)',
        $self->client->loginid,
        $args{to_account}, $account->{attributes}{account_code});

    my $txn;
    try {
        $txn = $self->client_payment(
            payment_type => 'dxtrade_transfer',
            amount       => -$args{amount},        # negative!
            fees         => $tx_amounts->{fees},
            remark       => $remark,
            txn_details  => \%txn_details,
        );
    } catch {
        die +{error_code => 'DXDepositFailed'};
    }

    my $resp = $self->call_api(
        $account->{account_type},
        'account_deposit',
        account_code  => $account->{attributes}{account_code},
        clearing_code => $account->{attributes}{clearing_code},
        id            => $self->unique_id,                        # must be unique for deposits on this login
        amount        => $tx_amounts->{recv_amount},
        currency      => $account->{currency},
    );
    die +{error_code => 'DXDepositIncomplete'} unless $resp->{success};

    $self->insert_payment_details($txn->payment_id, $args{to_account}, $tx_amounts->{recv_amount});

    my $update = $self->call_api(
        $account->{account_type},
        'account_get',
        account_code  => $account->{attributes}{account_code},
        clearing_code => $account->{attributes}{clearing_code},
    );
    die +{error_code => 'DXTransferCompleteError'} unless $update->{success};

    $self->client->user->daily_transfer_incr('dxtrade');
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

=item * C<amount> in dxtrad account currency.

=item * C<from_account>. Our dxtrade account id.

=back

Returns transaction id in hashref.

=cut

sub withdraw {
    my ($self, %args) = @_;

    my $account = $self->client->user->loginid_details->{$args{from_account}}
        or die +{error_code => 'DXInvalidAccount'};

    # Sequence:
    # 1. Validation
    # 2. Withdraw from dxtrade
    # 3. Deposit to deriv

    my $tx_amounts = $self->validate_transfer(
        action            => 'withdrawal',
        amount            => $args{amount},
        platform_currency => $account->{currency},
        account_type      => $account->{account_type},
        currency          => $args{currency},
    );

    my $resp = $self->call_api(
        $account->{account_type},
        'account_withdrawal',
        account_code  => $account->{attributes}{account_code},
        clearing_code => $account->{attributes}{clearing_code},
        id            => $self->unique_id,                        # must be unique for withdrawals on this login
        amount        => $args{amount},
        currency      => $account->{currency},
    );

    die +{error_code => 'DXInsufficientBalance'}
        if $resp->{content}{error_code}
        and $resp->{content}{error_code} eq '30005'
        and $resp->{status} eq '422';

    die +{error_code => 'DXWithdrawalFailed'} unless $resp->{success};

    my %txn_details = (
        dxtrade_account_id        => $args{from_account},
        fees                      => $tx_amounts->{fees},
        fees_percent              => $tx_amounts->{fees_percent},
        fees_currency             => $account->{currency},                      # sending account
        min_fee                   => $tx_amounts->{min_fee},
        fee_calculated_by_percent => $tx_amounts->{fee_calculated_by_percent});

    my $remark = sprintf(
        'Transfer from dxtrade account %s (account id %s) to %s',
        $args{from_account},
        $account->{attributes}{account_code},
        $self->client->loginid
    );

    my $txn;
    try {
        $txn = $self->client_payment(
            payment_type => 'dxtrade_transfer',
            amount       => $tx_amounts->{recv_amount},
            fees         => $tx_amounts->{fees_in_client_currency},
            remark       => $remark,
            txn_details  => \%txn_details,
        );
    } catch {
        die +{error_code => 'DXWithdrawalIncomplete'};
    }

    $self->insert_payment_details($txn->payment_id, $args{from_account}, -$args{amount});

    my $update = $self->call_api(
        $account->{account_type},
        'account_get',
        account_code  => $account->{attributes}{account_code},
        clearing_code => $account->{attributes}{clearing_code},
    );
    die +{error_code => 'DXTransferCompleteError'} unless $update->{success};

    $self->client->user->daily_transfer_incr('dxtrade');
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
        $account->{account_type},
        'account_get',
        account_code  => $account->{attributes}{account_code},
        clearing_code => $account->{attributes}{clearing_code},
    );

    die +{
        error_code     => 'DXDemoTopupBalance',
        message_params => [formatnumber('amount', 'USD', DEMO_TOPUP_MINIMUM_BALANCE), 'USD']}
        unless $check->{content}{balance} <= DEMO_TOPUP_MINIMUM_BALANCE;

    my $resp = $self->call_api(
        $account->{account_type},
        'account_deposit',
        account_code  => $account->{attributes}{account_code},
        clearing_code => $account->{attributes}{clearing_code},
        id            => $self->unique_id,                        # must be unique for deposits on this login
        amount        => DEMO_TOPUP_AMOUNT,
        currency      => $account->{currency},
    );
    die +{error_code => 'DXDemoTopFailed'} unless $resp->{success};

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
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 get_account_info

The DXTrader implementation of getting an account info.

=cut

sub get_account_info {
    my ($self, $loginid) = @_;

    my @accounts = @{$self->get_accounts};

    my $account = first { $_->{account_id} eq $loginid } @accounts;

    die "DXInvalidAccount\n" unless ($account);

    return $account;
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
            $config->{service_url} = 'http://localhost:' . $ENV{DEVEXPERTS_API_SERVICE_PORT};
        } else {
            $config->{service_url} = $config->{service}{host} // 'http://localhost';
            $config->{service_url} .= ':' . $config->{service}{port} if $config->{service}{port};
        }
        $config;
    }
}

=head2 call_api

Calls API service with given $method and %parmams.

Takes the following arguments:

=over 4

=item * C<method> (required).

=item * C<args>. Arguments to method.

=back

=cut

sub call_api {
    my ($self, $server, $method, %args) = @_;

    my $payload = encode_json_utf8({
        server => $server,
        method => $method,
        %args
    });
    try {
        my $resp = $self->http->post($self->config->{service_url}, {content => $payload});
        $resp->{content} = decode_json_utf8($resp->{content} || '{}');
        return $resp;
    } catch ($e) {
        return {};
    }
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

    return undef if BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all;

    my $login = $self->dxtrade_login;

    my $api_resp = $self->call_api(
        $server,
        'client_get',
        login  => $login,
        domain => DX_DOMAIN,
    );

    if ($api_resp->{content}{error_code} and $api_resp->{content}{error_code} eq '30002' and $api_resp->{status} eq '404') {
        # expected response for not found
        return undef;
    } elsif (!(exists $api_resp->{content}{login} and $api_resp->{content}{login} eq $login)) {
        die 'Failed to retrieve DevExperts client';
    } else {
        return $api_resp->{content};
    }
}

=head2 dxtrade_login

Gets the common login id for dxtrade. The same login is used for all accounts.

=cut

sub dxtrade_login {
    my $self = shift;

    if ($self->config->{real_account_ids}) {
        my $prefix = $self->config->{real_account_ids_login_prefix} // '';
        return $prefix . $self->client->user->id;
    } else {
        my $account = first { ($_->{platform} // '') eq 'dxtrade' } values $self->client->user->loginid_details->%*;
        return $account->{attributes}{login} if $account;
        return sha1_hex($$ . time . rand);
    }
}

=head2 account_details

Format account details for websocket response.

=cut

sub account_details {
    my ($self, $account) = @_;

    my $category    = first { $_->{category} eq 'Trading' } $account->{categories}->@*;
    my $market_type = $category->{value} eq 'Financials Only' ? 'financial' : 'synthetic';

    return {
        login                 => $account->{login},
        account_id            => $account->{account_id},
        account_type          => $account->{account_type} eq 'LIVE' ? 'real' : 'demo',
        balance               => financialrounding('amount', $account->{currency}, $account->{balance}),
        currency              => $account->{currency},
        display_balance       => formatnumber('amount', $account->{currency}, $account->{balance}),
        platform              => 'dxtrade',
        market_type           => $market_type,
        landing_company_short => 'svg',                                                                    #todo
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

1;
