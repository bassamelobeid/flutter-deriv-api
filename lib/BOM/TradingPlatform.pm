package BOM::TradingPlatform;

use strict;
use warnings;
no indirect;

=head1 NAME 

BOM::TradingPlatform - Trading platform interface.

=head1 SYNOPSIS 

    my $dxtrader = BOM::TradingPlatform->new(platform => 'dxtrade', client => $client);
    $dxtrader->deposit(...);

    my $mt5 = BOM::TradingPlatform->new(platform =>'mt5', client => $client);
    $dxtrader->deposit(...);

=head1 DESCRIPTION 

This module provide a layer of abstraction to our trading platforms.

Denotes the interface our trading platforms must implement to operate and integrate with
the rest of our system.

=cut

use Syntax::Keyword::Try;
use BOM::TradingPlatform::DXTrader;
use BOM::TradingPlatform::MT5;
use BOM::TradingPlatform::DerivEZ;
use BOM::TradingPlatform::CTrader;
use BOM::Config::Runtime;
use BOM::Platform::Client::CashierValidation;
use Format::Util::Numbers            qw(financialrounding);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use List::Util                       qw(first);

use constant CLASS_DICT => {
    mt5     => 'BOM::TradingPlatform::MT5',
    dxtrade => 'BOM::TradingPlatform::DXTrader',
    derivez => 'BOM::TradingPlatform::DerivEZ',
    ctrader => 'BOM::TradingPlatform::CTrader',
};
use constant INTERFACE => qw(
    new_account
    change_investor_password
    change_password
    deposit
    withdraw
    get_account_info
    get_accounts
    get_open_positions
);

for my $method (INTERFACE) {
    no strict "refs";
    *{"BOM::TradingPlatform::$method"} = sub {
        my ($self) = @_;
        die sprintf '%s not yet implemented by %s', $method, ref($self);
    }
}

=head2 name

Gets the name of the current trading platform instance.

=cut

sub name {
    my $class = ref(shift);

    for my $platform (keys CLASS_DICT->%*) {
        if ($class eq CLASS_DICT->{$platform}) {
            return $platform;
        }
    }

    return 'trading_platform';
}

=head2 new

Creates a new valid L<BOM::TradingPlatform> instance.

It takes the following parameters:

=over 4

=item * C<platform> The name of the trading platform being instantiated.

=item * C<client> Client instance.

=back

We curently support as valid trading platform names:

=over 4

=item * C<mt5> The MT5 trading platform.

=item * C<dxtrade> The DevExperts trading platform.

=item * C<rule_engine> (optional) A rule engine object for checking business rules. 
We don't want to create rule engine objects in bom-user repo to avoid circular dependency.

=back

Returns a valid implementation of L<BOM::TradingPlatform>

=cut

sub new {
    my (undef, %args) = @_;

    my $class = CLASS_DICT->{$args{platform}}
        or die "Unknown trading platform: $args{platform}";

    return $class->new(%args);
}

=head2 new_base

Creates a plaform-less instance of the base class, for tests.

=over 4

=item * C<client> Client instance.

=item * C<rule_engine> (optional) A rule engine object for checking business rules.

=back

Returns object.

=cut

sub new_base {
    my ($class, %args) = @_;

    return bless {
        client      => $args{client},
        user        => $args{user},
        rule_engine => $args{rule_engine}}, $class;
}

=head2 client

Returns client instance provided to new().

=cut

sub client {
    return shift->{client};
}

=head2 user

Returns user instance provided to new().

=cut

sub user {
    return shift->{user};
}

=head2 rule_engine

Returns rule_engine instance provided to new().

=cut

sub rule_engine {
    my $self = shift;

    die 'Rule engine object was not found. Please add it to the constructor args.' unless $self->{rule_engine};
    return $self->{rule_engine};
}

=head2 validate_transfer

Generic validation of transfers and fee calculation. There are no platform-specific checks here.

=over 4

=item * C<action>: deposit or withdrawal.

=item * C<amount>: amount to be sent from source account.

=item * C<amount_currency>: currency of the amount.

=item * C<platform_currency>: currency of platform account.

=item * C<request_currency>: currency param from websocket request.

=item * C<account_type>: type of platform account, demo or real

=item * C<landing_company_to>: landing company where we transfer money to 

=item * C<landing_company_from>: landing company where we transfer money from

=item * C<type>: type of trading account, demo or real.

=back

Returns hashref of validated amounts or dies with error.

=cut

sub validate_transfer {
    my ($self, %args) = @_;

    my ($action, $send_amount, $amount_currency, $platform_currency, $request_currency, $account_type, $payment_type) =
        @args{qw/action amount amount_currency platform_currency request_currency account_type payment_type/};
    my ($recv_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent, $fees_in_client_currency);

    $self->rule_engine->verify_action(
        'account_transfer',
        transfer_type    => $self->name,
        loginid          => $self->client->loginid,
        user             => $self->user,
        loginid_from     => $args{from_account},
        loginid_to       => $args{to_account},
        amount           => $send_amount,
        amount_currency  => $amount_currency,
        request_currency => $request_currency,        # only passed for transfer_between_accounts
    );

    $self->rule_engine->verify_action(
        "trading_account_$action", %args,
        platform => $self->name,
        loginid  => $self->client->loginid,
        %args{qw(landing_company_from landing_company_to account_type platform_currency)},
    );

    my $app_config = BOM::Config::Runtime->instance->app_config;
    die +{error_code => 'PlatformTransferSuspended'} if $app_config->system->suspend->payments;
    die +{error_code => 'PlatformTransferSuspended'} if $app_config->system->suspend->transfer_between_accounts;
    die +{error_code => 'PlatformTransferBlocked'}   if $self->client->status->transfers_blocked;

    die +{error_code => 'PlatformTransferNocurrency'} unless $self->client->account;
    my $local_currency = $self->client->account->currency_code;

    if (my $suspended_currency = first { $_ eq $local_currency or $_ eq $platform_currency } $app_config->system->suspend->transfer_currencies->@*) {
        die +{
            error_code => 'PlatformTransferCurrencySuspended',
            params     => [$suspended_currency],
        };
    }

    try {
        if ($action eq 'deposit') {

            ($recv_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
                BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees(
                amount        => $send_amount,
                from_currency => $local_currency,
                to_currency   => $platform_currency,
                country       => $self->client->residence,
                );
            $recv_amount = financialrounding('amount', $platform_currency, $recv_amount);
            $send_amount = $send_amount * -1;

        } elsif ($action eq 'withdrawal') {

            ($recv_amount, $fees, $fees_percent, $min_fee, $fee_calculated_by_percent) =
                BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees(
                amount        => $send_amount,
                from_currency => $platform_currency,
                to_currency   => $local_currency,
                country       => $self->client->residence,
                );

            $recv_amount = financialrounding('amount', $local_currency, $recv_amount);

            # fees are in source currency, but we need to record on client transaction in client currency
            $fees_in_client_currency = financialrounding('amount', $local_currency, convert_currency($fees, $platform_currency, $local_currency));
        }

    } catch {
        # probably due to outdated exchange rates
        die +{error_code => 'PlatformTransferTemporarilyUnavailable'}
    }

    try {
        $self->client->validate_payment(
            currency     => $local_currency,
            amount       => ($action eq 'deposit' ? $send_amount : $recv_amount),
            payment_type => $payment_type,
            rule_engine  => $self->rule_engine,
        );
    } catch ($e) {
        die +{
            error_code => 'PlatformTransferError',
            params     => [$e->{message_to_client}],
        };
    }

    return {
        recv_amount               => $recv_amount,
        fees                      => $fees,
        fees_percent              => $fees_percent,
        min_fee                   => $min_fee,
        fee_calculated_by_percent => $fee_calculated_by_percent,
        fees_in_client_currency   => $fees_in_client_currency,
    };
}

=head2 client_payment

Perform a transaction on client (deriv) account.

=over 4

=item * C<amount>: amount in account currency, negative for withdrawal.

=item * C<payment_type>: valid value from the payment.payment_type table.

=item * C<remark>: remark for internal/backoffice use, not displayed to the user.

=item * C<fees>: fees charged in account currency.

=item * C<txn_details>: hashref of fields used for making statement remarks to be displayed to the user.

=back

Returns a BOM::User::Client::PaymentTransaction object.

=cut

sub client_payment {
    my ($self, %args) = @_;

    my $account = $self->client->account;

    return $account->add_payment_transaction({
            account_id           => $account->id,
            amount               => $args{amount},
            payment_gateway_code => 'account_transfer',
            payment_type_code    => $args{payment_type},
            status               => 'OK',
            staff_loginid        => $self->client->loginid,
            remark               => $args{remark},
            transfer_fees        => $args{fees},
        },
        $args{payment_child} ? $args{payment_child} : undef,
        $args{txn_details},
    );
}

1;
