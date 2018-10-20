package BOM::Config::CurrencyConfig;

=head1 NAME

BOM::Config::CurrencyConfig

=head1 DESCRIPTION

A repository of dynamic configurations set on currencies, like their minimum/maximum limits.

=cut

use strict;
use warnings;

use JSON::MaybeUTF8;

use Format::Util::Numbers;
use LandingCompany::Registry;
use BOM::Config::Runtime;

=head2 transfer_between_accounts_limits

Transfer limits are returned as a {currency => {min => 1}, ... } hash ref (there are'nt any predefined maximum limits for now).
These values are extracted from app_config->payment.transfer_between_accounts.minimum, editable in backoffice Dynamic Settings page.

=cut

sub transfer_between_accounts_limits {
    my @all_currencies = LandingCompany::Registry::all_currencies();

    my $app_config = BOM::Config::Runtime->instance->app_config();
    my @keys       = (
        'payments.transfer_between_accounts.minimum.default.fiat',
        'payments.transfer_between_accounts.minimum.default.crypto',
        'payments.transfer_between_accounts.minimum.by_currency'
    );
    my $configs = $app_config->get([@keys]);

    my $configs_json = JSON::MaybeUTF8::decode_json_utf8($configs->{'payments.transfer_between_accounts.minimum.by_currency'});

    my %currency_min = map {
        my $type = LandingCompany::Registry::get_currency_type($_);
        my $min = $configs_json->{$_} // $configs->{"payments.transfer_between_accounts.minimum.default.$type"};
        $_ => {
            min => 0 + Format::Util::Numbers::financialrounding('price', $_, $min),
            }
    } @all_currencies;

    return \%currency_min;
}

1;
