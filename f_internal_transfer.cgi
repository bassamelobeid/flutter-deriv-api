#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi);
use f_brokerincludeall;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
use BOM::Backoffice::Utility      qw(master_live_server_error);
use BOM::Config;
use BOM::Config::Chronicle;
use BOM::Config::CurrencyConfig;
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Database::ClientDB;
use BOM::DynamicSettings;
use Data::Compare;
use HTML::Entities;
use LandingCompany::Registry;
use List::Util qw(any);
use Log::Any   qw($log);
use Syntax::Keyword::Try;

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation('INTERNAL TRANSFER SETTINGS');

use constant EXCHANGE_RATE_SPREAD_NAMESPACE => 'exchange_rates_spread';

my $action = request()->url_for('backoffice/f_internal_transfer.cgi');

Bar("EXCHANGE RATE SPREAD");

sub get_exchange_rate_spreads_data {
    try {
        my $collector_db = BOM::Database::ClientDB->new({
                broker_code => 'FOG',
                operation   => 'collector',
            })->db->dbic;

        my @data = $collector_db->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM data_collection.get_exchange_rate_spreads()', {Slice => {}});
            });

        return @data;
    } catch ($error) {
        log->warn("Failed to fetch exchange rate spreads data - $error");
    }
}

sub update_spread_value {
    my ($currency_pair, $new_spread_value, $update_reason) = @_;

    try {
        my $collector_db = BOM::Database::ClientDB->new({
                broker_code => 'FOG',
                operation   => 'collector',
            })->db->dbic;

        $collector_db->run(
            fixup => sub {
                return $_->selectall_arrayref(
                    'SELECT * FROM data_collection.update_spread_value(?, ?, ?, ?)',
                    {Slice => {}},
                    $currency_pair, $new_spread_value, BOM::Backoffice::Auth::get_staffname(),
                    $update_reason
                );
            });

        # This if statement is necessary to avoid warnings of uninitialized value
        if (defined $currency_pair && defined $new_spread_value) {
            my $redis     = BOM::Config::Redis::redis_exchangerates_write();
            my $redis_key = EXCHANGE_RATE_SPREAD_NAMESPACE . "::$currency_pair";
            $redis->set($redis_key, $new_spread_value);
        }

        print "<p class=\"notify\">Successfully updated.</p>";
    } catch ($error) {
        print "<p class=\"notify notify--warning\">Failed to update.</p>";
        $log->errorf("Failed to update spread value %s - %s", $currency_pair, $error);
    }
}

if ($action && request()->http_method eq 'POST') {
    _show_error_and_exit(' not authorized to make this change ') unless (BOM::Backoffice::Auth::has_authorisation(['PaymentInternalTransfer']));

    my $currency_pair    = request()->param('symbol');
    my $new_spread_value = request()->param('new_spread');
    my $update_reason    = request()->param('reason');

    update_spread_value($currency_pair, $new_spread_value, $update_reason);
}

BOM::Backoffice::Request::template()->process(
    'backoffice/exchange_rate_spread.html.tt',
    {
        spread_data           => get_exchange_rate_spreads_data(),
        internal_transfer_url => $action,
    });

my @all_currencies = LandingCompany::Registry::all_currencies();
my $app_config     = BOM::Config::Runtime->instance->app_config();
my $config         = $app_config->get([
    'payments.transfer_between_accounts.fees.default.fiat_fiat',     'payments.transfer_between_accounts.fees.default.fiat_crypto',
    'payments.transfer_between_accounts.fees.default.fiat_stable',   'payments.transfer_between_accounts.fees.default.crypto_fiat',
    'payments.transfer_between_accounts.fees.default.stable_fiat',   'payments.transfer_between_accounts.fees.by_currency',
    'payments.transfer_between_accounts.fees.default.crypto_crypto', 'payments.transfer_between_accounts.fees.default.crypto_stable',
    'payments.transfer_between_accounts.fees.default.stable_crypto', 'payments.transfer_between_accounts.fees.default.stable_stable'
]);

my $fee_by_currency = $config->{'payments.transfer_between_accounts.fees.by_currency'};
my $fiat_fiat       = $config->{'payments.transfer_between_accounts.fees.default.fiat_fiat'};
my $fiat_crypto     = $config->{'payments.transfer_between_accounts.fees.default.fiat_crypto'};
my $fiat_stable     = $config->{'payments.transfer_between_accounts.fees.default.fiat_stable'};
my $crypto_crypto   = $config->{'payments.transfer_between_accounts.fees.default.crypto_crypto'};
my $crypto_fiat     = $config->{'payments.transfer_between_accounts.fees.default.crypto_fiat'};
my $crypto_stable   = $config->{'payments.transfer_between_accounts.fees.default.crypto_stable'};
my $stable_stable   = $config->{'payments.transfer_between_accounts.fees.default.stable_stable'};
my $stable_fiat     = $config->{'payments.transfer_between_accounts.fees.default.stable_fiat'};
my $stable_crypto   = $config->{'payments.transfer_between_accounts.fees.default.stable_crypto'};

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

my $defaults_msg = '';
my $currency_msg = '';

if ($submit) {
    my $new_fee_by_currency = request()->param('fee_by_currency');
    $new_fee_by_currency =~ s/\s//g;

    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
    if ($fee_by_currency ne $new_fee_by_currency) {
        $fee_by_currency = $new_fee_by_currency;
        $app_config->set({
            'payments.transfer_between_accounts.fees.by_currency' => $fee_by_currency,
        });
        $currency_msg = "<p class='success'><strong>SUCCESS: Transfer fees by currency saved.</strong></p>";
    }

    if (   $fiat_fiat != request()->param('fiat_fiat')
        or $fiat_crypto != request()->param('fiat_crypto')
        or $fiat_stable != request()->param('fiat_stable')
        or $crypto_fiat != request()->param('crypto_fiat')
        or $stable_fiat != request()->param('stable_fiat')
        or $crypto_crypto != request()->param('crypto_crypto')
        or $crypto_stable != request()->param('crypto_stable')
        or $stable_crypto != request()->param('stable_crypto')
        or $stable_stable != request()->param('stable_stable'))
    {
        $fiat_fiat     = request()->param('fiat_fiat');
        $fiat_crypto   = request()->param('fiat_crypto');
        $fiat_stable   = request()->param('fiat_stable');
        $crypto_crypto = request()->param('crypto_crypto');
        $crypto_fiat   = request()->param('crypto_fiat');
        $crypto_stable = request()->param('crypto_stable');
        $stable_fiat   = request()->param('stable_fiat');
        $stable_crypto = request()->param('stable_crypto');
        $stable_stable = request()->param('stable_stable');

        $app_config->set({
            'payments.transfer_between_accounts.fees.default.fiat_fiat'     => $fiat_fiat,
            'payments.transfer_between_accounts.fees.default.fiat_crypto'   => $fiat_crypto,
            'payments.transfer_between_accounts.fees.default.fiat_stable'   => $fiat_stable,
            'payments.transfer_between_accounts.fees.default.crypto_crypto' => $crypto_crypto,
            'payments.transfer_between_accounts.fees.default.crypto_fiat'   => $crypto_fiat,
            'payments.transfer_between_accounts.fees.default.crypto_stable' => $crypto_stable,
            'payments.transfer_between_accounts.fees.default.stable_fiat'   => $stable_fiat,
            'payments.transfer_between_accounts.fees.default.stable_crypto' => $stable_crypto,
            'payments.transfer_between_accounts.fees.default.stable_stable' => $stable_stable
        });
        $defaults_msg = "<p class='success'><strong>SUCCESS: Default transfer fees saved.</strong></p>";
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
        crypto_crypto     => $crypto_crypto,
        crypto_fiat       => $crypto_fiat,
        crypto_stable     => $crypto_stable,
        stable_crypto     => $stable_crypto,
        stable_fiat       => $stable_fiat,
        stable_stable     => $stable_stable,
        fee_by_currency   => $fee_by_currency,
        max_percent       => $max_fee_percent,
        disabled          => 0,
        countries         => request()->brand->countries_instance->countries_list,
    });

#DYNAMIC SETTINGS FOR INTERNAL TRANSFER
my $settings_list = [@{BOM::DynamicSettings::get_settings_by_group('internal_transfer')}];

Bar("SETTINGS FOR INTERNAL TRANSFER");

if (!any { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}}) {
    print '<div id="message"><div id="error">' . master_live_server_error() . '</div></div><br />';
} else {
    BOM::DynamicSettings::save_settings({
        'settings'          => request()->params,
        'settings_in_group' => $settings_list,
        'save'              => request()->param('submitted'),
    });
}

my $title = "SETTINGS FOR INTERNAL TRANSFER";

my @send_to_template = BOM::DynamicSettings::generate_settings_branch({
    settings          => [BOM::Config::Runtime->instance->app_config->all_keys()],
    settings_in_group => $settings_list,
    group             => 'internal_transfer',
    title             => $title,
    submitted         => request()->param('page'),
});

BOM::Backoffice::Request::template()->process(
    'backoffice/dynamic_settings_internal_transfer.html.tt',
    {
        settings => \@send_to_template,
    });

code_exit_BO();
