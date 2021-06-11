package BOM::User::Script::BalanceRescinder;

use strict;
use warnings;
no indirect;

use JSON::MaybeXS qw(encode_json);
use BOM::Platform::Email qw(send_email);
use BOM::User::Client;
use Log::Any qw($log);
use Date::Utility;
use Syntax::Keyword::Try;
use BOM::Platform::Context qw(request);
use Format::Util::Numbers qw(formatnumber);

=head1 NAME 

BOM::User::BalanceRescinder - Set of functions related to the balance rescinder cron script.

=head1 SYNOPSIS 

    my $broker_code = 'CR';
    BOM::User::Script::BalanceRescinder->new(broker_code => $broker_code)->run;

=head1 DESCRIPTION 

This module is used by `balance_rescinder.pl` script. Meant to provide a testable
collection of subroutines.

This package rescinds the balance of disabled accounts that meet the following criteria:

=over 4

=item * more than 30 days since the account has been disabled

=item * for fiat currencies (and stable coins) the balance should be equal/less than 1

=item * for crypto currencies the balance should be equal/less than 1 USD at current conversion rates

=item * even though it's implied the balance should be more than 0 to rescind it

=back

=cut

use ExchangeRates::CurrencyConverter qw(convert_currency);
use LandingCompany::Registry;
use BOM::Database::ClientDB;
use Moo;

=head2 broker_code

The broker code we are operating.

=cut

has 'broker_code' => (
    is       => 'ro',
    required => 1,
);

=head2 summary

Keeps an internal state of the accounts whose balances have been rescinded.

=cut

has 'summary' => (
    is      => 'rw',
    default => sub { {} },
);

has 'dbic' => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_dbic',
);

has 'landing_company' => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_landing_company',
);

has 'currencies' => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_currencies',
);

use constant DISABLED_DAYS_REQUIRED     => 30;
use constant FIAT_BALANCE_LIMIT         => 1;
use constant CRYPTO_CONVERSION_AMOUNT   => 1;
use constant CRYPTO_CONVERSION_CURRENCY => 'USD';

=head2 _build_dbic

Builds a L<BOM::Database::ClientDB> dbic for our broker code.

=cut

sub _build_dbic {
    my $self = shift;

    return BOM::Database::ClientDB->new({broker_code => $self->broker_code})->db->dbic;
}

=head2 _build_landing_company

Builds a L<LandingCompany> from our broker code

=cut

sub _build_landing_company {
    my $self = shift;

    return LandingCompany::Registry->get_by_broker($self->broker_code);
}

=head2 run

Runs the script for the desired broker code.

Returns undef.

=cut

sub run {
    my ($self) = @_;

    try {
        my $accounts = $self->accounts;
        $log->debugf('Attempting to rescind %d accounts on %s', scalar keys $accounts->%*, $self->broker_code);

        for my $account (values $accounts->%*) {
            $self->rescind($account->{client_loginid}, $account->{currency_code}, $account->{balance});
        }

        $self->sendmail;
    } catch ($e) {
        $log->debugf('Error while processing balance rescind on %s: %s', $self->broker_code, $e);
    }
}

=head2 accounts 

This subroutine is a wrapper for `transaction.get_rescindable_loginids` db function.

With this subroutine we can fetch the disabled accounts whose balance can be rescinded given
our business logic rules. Roughly speaking:

=over 4 

=item * status should be disabled

=item * must've been disabled for more than 30 days (by default)

=item * balance should be more than 0 but equal/less than 1 (fiat currencies and stable coins) or 1 USD equivalent (crypto currencies)

=back

It takes the following argument:

=over 4

=item * C<days> (optional) the number of days we should look back, 30 days by default

=item * C<currencies> (optional) a simple hashref containing currency codes as keys and the maximum amount for rescinding as values, will build this structure if not given

=back

Returns an hashref of hashrefs including:

=over 4

=item * C<client_loginid> the loginid of the account

=item * C<currency_code> the currency of the account

=item * C<balance> the balance of the account

=back

=cut

sub accounts {
    my ($self, $days, $currencies) = @_;
    $days       //= DISABLED_DAYS_REQUIRED;
    $currencies //= $self->currencies;

    my $dbic   = $self->dbic;
    my $sql    = "SELECT * FROM transaction.get_rescindable_loginids(?, ?)";
    my $result = $dbic->run(
        fixup => sub {
            $_->selectall_hashref($sql, 'client_loginid', undef, $days, encode_json($currencies));
        });

    return $result;
}

=head2 _build_currencies 

Computes the structure needed by the `transaction.get_rescindable_loginids` db function
in order to fetch the rescindable accounts.

We will grab the currencies of the broker code and fill a hashref given these two simple rules:

=over 4 

=item * if the currency is fiat or a stable coin, the value is 1

=item * if the currency is a crypto, the value is 1 USD equivalent

=back

Returns a hashref of currency codes mapping to the amounts mentioned before.

=cut

sub _build_currencies {
    my ($self) = @_;
    my $currencies = {};

    for my $currency (keys $self->landing_company->legal_allowed_currencies->%*) {
        my $type   = $self->landing_company->legal_allowed_currencies->{$currency}->{type};
        my $stable = $self->landing_company->legal_allowed_currencies->{$currency}->{stable};
        my $amount = FIAT_BALANCE_LIMIT;

        if ($type ne 'fiat' && !$stable) {
            $amount = eval { convert_currency(CRYPTO_CONVERSION_AMOUNT, CRYPTO_CONVERSION_CURRENCY, $currency) };
        }

        unless (defined $amount) {
            $log->debugf('Could not convert %s to USD we will skip this currency this round', $currency);
            next;
        }

        $currencies->{$currency} = $amount;
    }

    return $currencies;
}

=head2 rescind

Rescind the balance from the given loginid.

This method will also update the internal state of the `summary` hashref.

It takes the following arguments:

=over 4

=item C<loginid> the loginid of the client to rescind

=item C<currency> the currency of the account being rescinded

=item C<amount> the amount being rescinded

=back

It updates the state of the internal `summary` hashref, 
this hashref uses the client loginid as keys whose values are hashref described as:

=over 4

=item C<currency> the currency code of the account

=item C<amount> the amount rescinded

=back

It returns 1 on success, 0 otherwise.

=cut

sub rescind {
    my ($self, $loginid, $currency, $amount) = @_;

    my $client = BOM::User::Client->new({loginid => $loginid});

    return 0 unless $client;

    $client->payment_legacy_payment(
        currency     => $currency,
        amount       => -$amount,
        remark       => 'Balance automatically rescinded for disabled account',
        payment_type => 'closed_account',
    );

    $self->summary->{$loginid} = {
        currency => $currency,
        amount   => $amount,
    };

    return 1;
}

=head2 sendmail

Sends an email to payments based on the rescind summary.

Returns undef.

=cut

sub sendmail {
    my ($self) = @_;

    $log->debugf('Attempting to send summary email for %d rescinded accounts on %s', scalar keys $self->summary->%*, $self->broker_code);

    return undef unless scalar keys $self->summary->%*;

    my $broker_code = $self->broker_code;
    my $messages    = [];

    for my $loginid (keys $self->summary->%*) {
        my $currency = $self->summary->{$loginid}->{currency};
        my $amount   = formatnumber('amount', $currency, $self->summary->{$loginid}->{amount});
        push $messages->@*, "<tr><td>$loginid</td><td>$currency</td><td>$amount</td></tr>";
    }

    my $stamp = Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ;
    my $brand = request()->brand;

    send_email({
            from                  => $brand->emails('no-reply'),
            to                    => $brand->emails('accounting'),
            subject               => "Automatically rescinded balances on $broker_code $stamp",
            email_content_is_html => 1,
            message               => [
                '<p>The balances of the following disabled accounts have been automatically rescinded:<p>',
                '<table border=1>',
                '<tr><th>Login ID</th><th>Currency</th><th>Rescinded amount</th></tr>',
                $messages->@*, '</table>'
            ],
        });

    return undef;
}

1
