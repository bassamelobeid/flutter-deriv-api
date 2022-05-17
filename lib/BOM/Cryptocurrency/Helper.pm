package BOM::Cryptocurrency::Helper;

use strict;
use warnings;
no indirect;

use BOM::Backoffice::Request;
use ExchangeRates::CurrencyConverter qw(in_usd);

use Exporter qw/import/;

our @EXPORT_OK = qw(render_message render_currency_info);

=head2 render_message

Renders the result output with proper HTML tags and color.

=over

=item * C<$is_success> - A boolean value whether it is a success or failure

=item * C<$message> - The message text

=back

Returns the message as a string containing HTML tags.

=cut

sub render_message {
    my ($is_success, $message) = @_;

    my ($class, $title) = $is_success ? ('success', 'SUCCESS') : ('error', 'ERROR');
    return "<p class='$class'><strong>$title:</strong> $message</p>";
}

=head2 render_currency_info

Renders the general information and configuration of a cryptocurrency.

=over 4

=item * C<$currency_code> - The currency code to render its info

=back

=cut

sub render_currency_info {
    my ($currency_code) = @_;

    my $currency_wrapper = BOM::CTC::Currency->new(currency_code => $currency_code);

    my $exchange_rate         = eval { in_usd(1.0, $currency_code) } // 'N.A.';
    my $main_address          = $currency_wrapper->account_config->{account}->{address};
    my $sweep_limit_max       = $currency_wrapper->sweep_max_transfer();
    my $sweep_limit_min       = $currency_wrapper->sweep_min_transfer();
    my $sweep_reserve_balance = $currency_wrapper->sweep_reserve_balance();

    BOM::Backoffice::Request::template()->process(
        'backoffice/crypto_cashier/crypto_info.html.tt',
        {
            exchange_rate         => $exchange_rate,
            currency              => $currency_code,
            main_address          => $main_address,
            sweep_limit_max       => $sweep_limit_max,
            sweep_limit_min       => $sweep_limit_min,
            sweep_reserve_balance => $sweep_reserve_balance,
        }) || die BOM::Backoffice::Request::template()->error() . "\n";
}

1;
