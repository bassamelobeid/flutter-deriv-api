package BOM::User::Script::BalanceRescinder;

use strict;
use warnings;
no indirect;

use JSON::MaybeXS        qw(encode_json);
use BOM::Platform::Email qw(send_email);
use BOM::User::Client;
use Log::Any qw($log);
use Date::Utility;
use Syntax::Keyword::Try;
use BOM::Platform::Context qw(request);
use Format::Util::Numbers  qw(formatnumber);
use List::Util             qw(none);

=head1 NAME

BOM::User::BalanceRescinder - Set of functions related to the balance rescinder cron script.

=head1 SYNOPSIS

    my $broker_code = 'CR';
    BOM::User::Script::BalanceRescinder->new(broker_code => $broker_code)->run;

=head1 DESCRIPTION

This module is used by `balance_rescinder.pl` script. Meant to provide a testable
collection of subroutines.

This package rescinds the balance of disabled accounts that meet criteria defined in CONFIG constant.

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

# processing will occur in this order.
# desc is the human readable descripion, used in the report email.
use constant CONFIG => [{
        desc     => 'Locked for more than 1 year and balance no more than 500',
        days     => 365,
        amount   => 500,
        statuses => [
            qw(cashier_locked no_trading no_withdrawal_or_trading disabled duplicate_account mt5_withdrawal_locked shared_payment_method unwelcome withdrawal_locked)
        ],
    },
    {
        desc     => 'Disabled for more than 30 days and balance no more than 1',
        days     => 30,
        amount   => 1,
        statuses => ['disabled'],
    },
    {
        desc         => 'Locked for more than 1 year, do not check the balance',
        days         => 365,
        amount       => undef,                                                     # undef means we don't care about the client balance
        statuses     => ['disabled'],
        broker_codes => [qw/CR/],
    },
];

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

    return LandingCompany::Registry->by_broker($self->broker_code);
}

=head2 run

Runs the script for the desired broker code.

Returns result of BOM::Platform::Email::send_email..

=cut

sub run {
    my ($self) = @_;
    my %result;

    for my $config (CONFIG->@*) {
        $result{$config->{desc}} = $self->process_accounts(%$config);
    }

    return $self->sendmail(\%result);
}

=head2 process_accounts 

Rescind accounts according to parameters.

=over 4

=item * C<desc> human readable description of the criteria.

=item * C<statuses> account must have one of these statuses

=item * C<days> the status was applied at least this number of days ago

=item * C<amount> account has less or equal to this amount in fiat, or in USD value for crypto. If C<undef> we don't care about the balance of the client.

=item * C<broker_codes> an array of broker code the rule must apply to.

=back

Returns an arrayref of accounts, or string with error.

=cut

sub process_accounts {
    my ($self, %args) = @_;
    my $result;

    return undef if $args{broker_codes} and none { $_ eq $self->broker_code } $args{broker_codes}->@*;

    try {
        $log->debugf('Getting accounts for %s on %s', $args{desc}, $self->broker_code);

        my $currencies = encode_json($self->currencies($args{amount}));
        my $accounts   = $self->dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT * FROM transaction.get_rescindable_loginids(?, ?, ?)',
                    {Slice => {}},
                    $args{days}, $currencies, $args{statuses});
            });

        $log->debugf('There are %d rescindable accounts on %s', scalar @$accounts, $self->broker_code);

        for my $account (@$accounts) {
            my $error = $self->rescind(%$account);
            push @$result, {%$account, error => $error};
        }
    } catch ($e) {
        $log->errorf('Error processing %s on %s: %s', $args{desc}, $self->broker_code, $e);
        $result = sprintf('Error processing %s: %s', $self->broker_code, $e);
    }
    return $result;
}

=head2 currencies 

Computes the structure needed by the `transaction.get_rescindable_loginids` db function
in order to fetch the rescindable accounts.
We will grab the currencies of the broker code and fill a hashref given these 3 simple rules:

=over 4 

=item * if the currency is fiat or a stable coin, the value is 1

=item * if the currency is a crypto, the value is 1 USD equivalent

=item * if te amount is C<undef>, the result is C<undef>

=back

It takes the following argument:

=over 4

=item * C<amount>

=back

Returns a hashref of currency codes mapping to the amounts mentioned before.

=cut

sub currencies {
    my ($self, $amount) = @_;
    my $currencies = {};

    for my $currency (keys $self->landing_company->legal_allowed_currencies->%*) {
        try {
            my $conv_amount = $amount;

            if (defined $amount) {
                my $type   = $self->landing_company->legal_allowed_currencies->{$currency}->{type};
                my $stable = $self->landing_company->legal_allowed_currencies->{$currency}->{stable};

                if ($type ne 'fiat' && !$stable) {
                    $conv_amount = convert_currency($amount, 'USD', $currency);
                }
            }

            $currencies->{$currency} = $conv_amount;
        } catch ($e) {
            $log->debugf('Could not convert USD to %s, we will skip this currency this round: %s', $currency, $e);
        }
    }

    return $currencies;
}

=head2 rescind

Rescind the balance from the given loginid.

It takes the following named arguments:

=over 4

=item C<client_loginid> the loginid of the client to rescind

=item C<currency_code> the currency of the account being rescinded

=item C<balance> amount to rescind

=back

It returns error message on failure, undef otherwise.

=cut

sub rescind {
    my ($self, %param) = @_;

    my $client = BOM::User::Client->new({loginid => $param{client_loginid}});

    return 'No client' unless $client;

    try {
        $client->payment_legacy_payment(
            currency     => $param{currency_code},
            amount       => -$param{balance},
            remark       => 'Balance automatically rescinded for disabled account',
            payment_type => 'closed_account',
        );
    } catch ($e) {
        $log->errorf('Error rescinding account for %s: %s', $param{client_loginid}, $e);
        return $e;
    }

    return undef;
}

=head2 sendmail

Sends an email to payments with summary of rescinded accounts.

=over 4

=item C<data> hashref keyed by criteria description

=back

Returns result of BOM::Platform::Email::send_email.

=cut

sub sendmail {
    my ($self, $data) = @_;

    return if none { defined $_ } values %$data;

    $log->debugf('Attempting to send summary email for %s', $self->broker_code);

    my @lines;
    for my $type (keys %$data) {
        if (ref $data->{$type}) {
            push @lines, "<p>$type:<p>", '<table border=1>',
                '<tr><th>Login ID</th><th>Currency</th><th>Rescinded amount</th><th>Account status</th></tr>';
            for my $account ($data->{$type}->@*) {
                my ($loginid, $currency, $amount, $error) = $account->@{qw(client_loginid currency_code balance error)};
                $amount = $error ? "0 - $error" : formatnumber('amount', $currency, $amount);
                my $statuses = join ', ', $account->{statuses}->@*;
                push @lines, "<tr><td>$loginid</td><td>$currency</td><td>$amount</td><td>$statuses</td></tr>";
            }
            push @lines, '</table>';
        } else {
            push @lines, "<p>$type: " . ($data->{$type} // 'no accounts to rescind') . '</p>';
        }
    }

    my $broker_code = $self->broker_code;
    my $stamp       = Date::Utility->new->datetime_ddmmmyy_hhmmss_TZ;
    my $brand       = request()->brand;

    return send_email({
        from                  => $brand->emails('no-reply'),
        to                    => $brand->emails('payments_tl'),
        subject               => "Automatically rescinded balances on $broker_code $stamp",
        email_content_is_html => 1,
        message               => \@lines,
    });
}

1
