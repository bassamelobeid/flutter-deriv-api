package BOM::TradingPlatform::DXTrader;

use strict;
use warnings;
no indirect;

use Syntax::Keyword::Try;
use YAML::XS;
use HTTP::Tiny;
use JSON::MaybeUTF8 qw(:v1);
use BOM::Config::Runtime;
use List::Util qw(first any);
use Format::Util::Numbers qw(financialrounding formatnumber);
use Digest::SHA1 qw(sha1_hex);

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
    DX_CLEARING_CODE => 'default',
    DX_DOMAIN        => 'default',
    HTTP_TIMEOUT     => 30,
};

=head2 new

Creates and returns a new L<BOM::TradingPlatform::DXTrader> instance.

=cut

sub new {
    return bless {}, 'BOM::TradingPlatform::DXTrader';
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

    my $account_type = $args{account_type} eq 'real' ? 'LIVE' : 'DEMO';
    my $currency     = $args{currency};
    unless ($currency) {
        die +{error_code => 'DXtradeNoCurrency'} unless $self->client->account;
        $currency = $self->client->account->currency_code;
    }

    my $trading_category = 'test';    # todo: set from %args, residence etc.

    my $password = $args{password};
    if (BOM::Config::Runtime->instance->app_config->system->suspend->universal_password) {
        die 'password required' unless $password;
    } else {
        $password = $self->client->user->password;
    }

    my $dxclient = $self->dxclient_get;

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
            error_code     => 'ExistingDXtradeAccount',
            message_params => [$existing->{account_code}]} if $existing;
        # todo: if password provided, change it or die
    } else {
        # no existing client, try to create one
        die 'password required' unless $password;
        my $login       = $self->config->{real_account_ids} ? $self->client->user->id : sha1_hex($$ . time . rand);
        my $client_resp = $self->call_api(
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

    my $account_code = $self->config->{real_account_ids} ? $seq_num         : sha1_hex($$ . time . rand);    # dx account id
    my $account_id   = $args{account_type} eq 'real'     ? 'DXR' . $seq_num : 'DXD' . $seq_num;              # our login

    my $account_resp = $self->call_api(
        'client_account_create',
        login         => $dxclient->{login},
        domain        => $dxclient->{domain},
        account_code  => $account_code,
        clearing_code => DX_CLEARING_CODE,
        account_type  => $account_type,
        currency      => $currency,
        categories    => [{
                category => 'Trading',
                value    => $trading_category,
            }
        ],
    );

    die 'Failed to create DevExperts account' unless exists $account_resp->{success};
    my $account = $account_resp->{content};
    die 'Created account does not have requested account code' unless $account->{account_code} eq $account_code;

    my %attributes = (
        login            => $dxclient->{login},
        trading_category => $trading_category,
        client_domain    => $dxclient->{domain},
        account_code     => $account->{account_code},
        clearing_code    => $account->{clearing_code},
    );

    $self->client->user->add_loginid($account_id, 'dxtrade', $args{account_type}, $account->{currency}, \%attributes);

    $account->{account_id} = $account_id;
    $account->{login}      = $dxclient->{login};
    return $self->account_details($account);
}

=head2 get_accounts

Gets all client accounts and returns list formatted for websocket response.

=cut

sub get_accounts {
    my ($self) = @_;

    my $dxclient = $self->dxclient_get;
    return [] unless $dxclient and $dxclient->{accounts};

    my @accounts;
    my $logins = $self->client->user->loginid_details;

    for my $login (sort keys %$logins) {
        next unless ($logins->{$login}{platform} // '') eq 'dxtrade';
        if (my $account = first { $_->{account_code} eq $logins->{$login}{attributes}{account_code} } $dxclient->{accounts}->@*) {
            $account->{account_id} = $login;
            $account->{login}      = $logins->{$login}{attributes}{login};
            push @accounts, $self->account_details($account);
        }
    }
    return \@accounts;
}

=head2 change_password

Changes the password of the client in DevExperts.

Takes the following arguments as named parameters:

=over 4

=item * C<password> (required). the new password.

=back

Returnds undef on success, dies on error.

=cut

sub change_password {
    my ($self, %args) = @_;

    my $password = $args{password};
    if (BOM::Config::Runtime->instance->app_config->system->suspend->universal_password) {
        die +{error_code => 'PasswordRequired'} unless $password;
    } else {
        $password = $self->client->user->password;
    }

    my $dxclient = $self->dxclient_get;
    die +{error_code => 'ClientNotFound'} unless $dxclient;

    my $resp = $self->call_api(
        'client_update',
        login    => $dxclient->{login},
        domain   => $dxclient->{domain},
        password => $password,
    );

    return undef if $resp->{success};

    die +{error_code => 'CouldNotChangePassword'};
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

=head2 deposit

The DXTrader implementation of making a deposit.

=cut

sub deposit {
    my ($self, $args) = @_;

    # TODO: should call BOM::DevExperts::User related method

    return $args;
}

=head2 withdraw

The DXTrader implementation of making a withdrawal.

=cut

sub withdraw {
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
        my $host   = $config->{service}{host}          // 'localhost';
        my $port   = $ENV{DEVEXPERTS_API_SERVICE_PORT} // $config->{service}{port};
        $config->{service_url} = "http://$host:$port";
        $config;
    }
}

=head2 call_api

Calls API service with given $method and %parmams.

=over 4

=item * C<method> (required).

=item * C<args>.

=back

=cut

sub call_api {
    my ($self, $method, %args) = @_;

    my $payload = encode_json_utf8({
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
    return shift->{http} // HTTP::Tiny->new(timeout => HTTP_TIMEOUT);
}

=head2 dxclient_get

Gets the devexperts client information of $self->client, if it exists.

=cut

sub dxclient_get {
    my ($self) = @_;

    my $login;
    if ($self->config->{real_account_ids}) {
        $login = $self->client->user->id;
    } else {
        my $account = first { ($_->{platform} // '') eq 'dxtrade' } values $self->client->user->loginid_details->%*;
        return undef unless $account;
        $login = $account->{attributes}{login};
    }

    my $api_resp = $self->call_api(
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

=head2 account_details

Format account details for websocket response.

=cut

sub account_details {
    my ($self, $account) = @_;

    return {
        login                 => $account->{login},
        account_id            => $account->{account_id},
        account_type          => $account->{account_type} eq 'LIVE' ? 'real' : 'demo',
        balance               => financialrounding('amount', $account->{currency}, $account->{balance}),
        currency              => $account->{currency},
        display_balance       => formatnumber('amount', $account->{currency}, $account->{balance}),
        platform              => 'dxtrade',
        market_type           => 'financial',                                                              #todo
        landing_company_short => 'svg',                                                                    #todo
        sub_account_type      => 'financial',                                                              #todo
    };
}

1;
