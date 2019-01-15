#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi);
use f_brokerincludeall;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::Config::Runtime;
use BOM::Config::CurrencyConfig;
use LandingCompany::Registry;

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation('INTERNAL TRANSFER FEES');

my @all_currencies = LandingCompany::Registry::all_currencies();
my $app_config     = BOM::Config::Runtime->instance->app_config();
my $config         = $app_config->get([
    'payments.transfer_between_accounts.fees.default.fiat_fiat',   'payments.transfer_between_accounts.fees.default.fiat_crypto',
    'payments.transfer_between_accounts.fees.default.fiat_stable', 'payments.transfer_between_accounts.fees.default.crypto_fiat',
    'payments.transfer_between_accounts.fees.default.stable_fiat', 'payments.transfer_between_accounts.fees.by_currency'
]);

my $fee_by_currency = $config->{'payments.transfer_between_accounts.fees.by_currency'};
my $fiat_fiat       = $config->{'payments.transfer_between_accounts.fees.default.fiat_fiat'};
my $fiat_crypto     = $config->{'payments.transfer_between_accounts.fees.default.fiat_crypto'};
my $fiat_stable     = $config->{'payments.transfer_between_accounts.fees.default.fiat_stable'};
my $crypto_fiat     = $config->{'payments.transfer_between_accounts.fees.default.crypto_fiat'};
my $stable_fiat     = $config->{'payments.transfer_between_accounts.fees.default.stable_fiat'};
$fee_by_currency =~ s/\s//g;    #remove line feeds for backward compatibility

my (@fiat, @crypto, @stable);
for my $currency (@all_currencies) {
    my $def = LandingCompany::Registry::get_currency_definition($currency);
    push @stable, "'$currency'" if $def->{stable};
    push @fiat,   "'$currency'" if ($def->{type} eq 'fiat');
    push @crypto, "'$currency'" if (($def->{type} eq 'crypto') and (not $def->{stable}));
}

# Get inputs
my $submit = request()->param('_form_submit');

my $action = request()->url_for('backoffice/quant/internal_transfer_fees.cgi');

my $defaults_msg = '';
my $currency_msg = '';
if ($submit) {
    my $new_fee_by_currency = request()->param('fee_by_currency');
    $new_fee_by_currency =~ s/\s//g;

    if ($fee_by_currency ne $new_fee_by_currency) {
        $fee_by_currency = $new_fee_by_currency;
        $app_config->set({
            'payments.transfer_between_accounts.fees.by_currency' => $fee_by_currency,
        });
        $currency_msg = "<p style='color:green'><strong>SUCCESS: Transfer fees by currency saved.</strong></p>";
    }

    if (   $fiat_fiat != request()->param('fiat_fiat')
        or $fiat_crypto != request()->param('fiat_crypto')
        or $fiat_stable != request()->param('fiat_stable')
        or $crypto_fiat != request()->param('crypto_fiat')
        or $stable_fiat != request()->param('stable_fiat'))
    {
        $fiat_fiat   = request()->param('fiat_fiat');
        $fiat_crypto = request()->param('fiat_crypto');
        $fiat_stable = request()->param('fiat_stable');
        $crypto_fiat = request()->param('crypto_fiat');
        $stable_fiat = request()->param('stable_fiat');

        $app_config->set({
            'payments.transfer_between_accounts.fees.default.fiat_fiat'   => $fiat_fiat,
            'payments.transfer_between_accounts.fees.default.fiat_crypto' => $fiat_crypto,
            'payments.transfer_between_accounts.fees.default.fiat_stable' => $fiat_stable,
            'payments.transfer_between_accounts.fees.default.crypto_fiat' => $crypto_fiat,
            'payments.transfer_between_accounts.fees.default.stable_fiat' => $stable_fiat
        });
        $defaults_msg = "<p style='color:green'><strong>SUCCESS: Default transfer fees saved.</strong></p>";
    }
}

binmode STDOUT, ':encoding(UTF-8)';

Bar("INTERNAL TRANSFER FEES");
my $max_fee_percent = BOM::Config::CurrencyConfig::MAX_TRANSFER_FEE;

BOM::Backoffice::Request::template()->process(
    'backoffice/quant/internal_transfer_fees.html.tt',
    {
        fiat_currencies   => join(',', sort @fiat),
        crypto_currencies => join(',', sort @crypto),
        stable_currencies => join(',', sort @stable),
        fiat_fiat         => $fiat_fiat,
        fiat_crypto       => $fiat_crypto,
        fiat_stable       => $fiat_stable,
        crypto_fiat       => $crypto_fiat,
        stable_fiat       => $stable_fiat,
        fee_by_currency   => $fee_by_currency,
        max_percent       => $max_fee_percent
    });

code_exit_BO();

