package BOM::RPC::v3::PaymentMethods;

=head1 NAME

BOM::RPC::v3::PaymentMethods

=head1 DESCRIPTION

This is a package contains the handler sub for `payment_methods` rpc call.

=cut

use strict;
use warnings;

use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use Time::Moment;
use List::Util qw(any uniq);
use Syntax::Keyword::Try;

use BOM::Config;
use BOM::Config::Redis;
use BOM::Config::Runtime;

use BOM::Platform::Context   qw(localize request);
use BOM::Platform::Doughflow qw(get_payment_methods);
use BOM::RPC::Registry '-dsl';
use BOM::RPC::v3::Utility;
use BOM::User::Client;
use Brands;
use LandingCompany::Registry;

=head2 payment_methods

Handle the C<payment_methods> API call.

As parameter receives a hashref with at least the following properties

=over 4

=item * C<args> - A hashref with the arguments received from the client.

=item * C<token_details> - A hashref with at least the attribute C<loginid>.

=back

The C<args> hashref should have the following atttributes :

=over 4

=item * C<payment_methods> - A number, always 1.

=item * C<country> - A string with the country as two letter code (ISO 3166-Alpha 2). Case insensitive.

=back

Will return a hashref with the payment_methods for this country brand/country code.

Further details about the structure can be found in L<BOM::Platform::Doughflow::get_payment_methods>.

=cut

rpc "payment_methods", sub {
    my $params        = shift;
    my $country       = $params->{args}->{country};
    my $token_details = $params->{token_details};
    my $brand         = request()->brand->name;

    my $client;
    if ($token_details and exists $token_details->{loginid}) {
        $client  = BOM::User::Client->new({loginid => $token_details->{loginid}});
        $country = $client->residence;
    }

    my $init = Time::Moment->now;
    try {
        my $payment_methods_list = get_payment_methods($country, $brand);
        my $p2p_payment_methods  = get_p2p_as_payment_method($country, $client);

        push @$payment_methods_list, $p2p_payment_methods if defined($p2p_payment_methods);
        stats_inc('bom_rpc.v_3.no_payment_methods_found.count') unless scalar @$payment_methods_list;

        stats_timing(
            'bom_rpc.v_3.payment_methods.running_time.success',
            $init->delta_milliseconds(Time::Moment->now),
            {tags => ['country:' . ($country || 'all'), 'client:' . ($client ? $client->{loginid} : 'none')]});

        return $payment_methods_list;
    } catch ($error) {
        stats_timing(
            'bom_rpc.v_3.payment_methods.running_time.error',
            $init->delta_milliseconds(Time::Moment->now),
            {tags => ['country:' . ($country || 'all'), 'client:' . ($client ? $client->{loginid} : 'none')]});
        if ($error =~ m/Unknown country code/) {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'UnknownCountryCode',
                    message_to_client => localize('Unknown country code.')});
        }

        die $error;
    }
};

=head2 get_p2p_as_payment_method

Returns p2p as payment method following the same structure used in Doughflow.

Parameters supported:

=over 4

=item * C<country> - A string with the country as two letter code (ISO 3166-Alpha2).

=item * C<client> - the L<BOM::User::Client> instance

=back

Returns a hash of the p2p information payment methods or undef in case of p2p is not supported in the country were passed.

It returns hashref described in L<BOM::Platform::Doughflow::get_payment_methods>

=cut

sub get_p2p_as_payment_method {
    my ($country, $client) = @_;

    return undef unless $country;

    my @short_codes = request()->brand->countries_instance->real_company_for_country($country);
    my ($p2p_lc) = grep { $_->{p2p_available} } map { LandingCompany::Registry->by_name($_) } @short_codes;

    my @restricted_countries = BOM::Config::Runtime->instance->app_config->payments->p2p->restricted_countries->@*;
    return undef if (!$p2p_lc || (any { $_ eq lc($country) } @restricted_countries));

    my @supported_currencies = map { uc($_) } @{BOM::Config::Runtime->instance->app_config->payments->p2p->available_for_currencies};
    my $limits               = p2p_limits(\@supported_currencies, $p2p_lc->{broker_codes}[0], $client, $country);

    return +{
        supported_currencies => \@supported_currencies,
        deposit_limits       => $limits->{deposit_limits},
        deposit_time         => '',
        description          => localize("DP2P is Deriv's peer-to-peer deposit and withdrawal service"),
        display_name         => 'DP2P',
        id                   => 'DP2P',
        payment_processor    => '',
        predefined_amounts   => [5, 10, 100, 300, 500],
        signup_link          => '',
        type_display_name    => 'P2P',
        type                 => '',
        withdraw_limits      => $limits->{withdraw_limits},
        withdrawal_time      => '',
    };
}

=head2 p2p_limits

Gets the min and max p2p deposit and withdraw limits

Takes the following argument:

=over 4

=item * C<landing_companies> - landing company of the client or country in request

=item * C<supported_currencies> - array ref of the supported currencies for p2p

=item * C<client> - the L<BOM::User::Client> instance

=item * C<country> - A string with the country as two letter code (ISO 3166-Alpha2)

=back

Returns hashref with C<deposit_limits> and C<withdraw_limits> as string key where each consist of hashrefs that have the following structure.
A string key with the 3-letter currency code, e.g. B<USD>, B<EUR>. The attributes for this hash ref are:

=over 4

=item * C<min> - Minimum amount of money required to deposit.

=item * C<max> - Maximum amount of money required to deposit.

=back

=cut

sub p2p_limits {
    my ($supported_currencies, $broker_code, $client, $country) = @_;

    $client //= BOM::Database::ClientDB->new({broker_code => $broker_code});

    my $res = {};
    for my $currency (@$supported_currencies) {
        my ($buy_limit, $sell_limit) = $client->db->dbic->run(
            fixup => sub {
                return $_->selectrow_array("SELECT daily_buy_limit, daily_sell_limit FROM p2p.get_trade_band_cfg(?,?,?)",
                    undef, $country, 'low', $currency);
            });

        $res->{deposit_limits}->{$currency} = {
            'max' => $buy_limit,
            'min' => 0
        };
        $res->{withdraw_limits}->{$currency} = {
            'max' => $sell_limit,
            'min' => 0
        };
    }

    return $res;
}

1;
