package BOM::TradingPlatform::Helper::HelperCTrader;

use strict;
use warnings;
no indirect;

use Locale::Country::Extra;
use Syntax::Keyword::Try;
use Digest::SHA            qw(sha384_hex);
use BOM::Platform::Context qw (request);
use Log::Any               qw($log);
use BOM::Config;

use base 'Exporter';
our @EXPORT_OK = qw(
    check_existing_account
    construct_new_trader_params
    construct_group_name
    get_ctrader_landing_company
    get_new_account_currency
    group_to_groupid
    is_valid_group
    traderid_from_traderlightlist
    get_ctrader_account_type
);

use constant CTRADER_ALL_LEVERAGE => 400000;
use constant CTRADER_DEFAULT_BALANCE => {
    live => 0,
    demo => 10000
};
use constant DEFAULT_ACCESS_RIGHTS => 'FULL_ACCESS';

=head2 _get_client_details

Get client details in format accepted by cTrader API.

=over 4

=item * C<client> - BOM::User::Client instance

=back

=cut

sub _get_client_details {
    my $client = shift;

    #Need to find out countryId system
    my $client_details = {
        name      => $client->first_name,
        lastName  => $client->last_name,
        email     => $client->email,
        address   => $client->address_1,
        state     => $client->state,
        city      => $client->city,
        zipCode   => $client->postcode,
        countryId => _country_to_countryid($client->residence),
        phone     => $client->phone,
    };

    return $client_details;
}

=head2 _country_to_countryid

Convert Alpha 2 type country code to country integer id defined by cTrader platform.

=over 4

=item * C<country> - Country code in lowercase Alpha 2 format

=back

=cut

sub _country_to_countryid {
    my $country          = shift;
    my $countryid_config = BOM::Config::ctrader_countryid();

    return $countryid_config->{$country}->{country_id};
}

=head2 get_ctrader_landing_company

Return the landing company for cTrader platform

=over 4

=item * C<client> - BOM::User::Client instance

=back

=cut

sub get_ctrader_landing_company {
    my ($client) = @_;

    my $brand = request()->brand;

    my $countries_instance = $brand->countries_instance;

    return $countries_instance->ctrader_company_for_country($client->residence);
}

=head2 get_new_account_currency

Resolves the default currency for the account based on Landing Company.

=over 4

=item * C<client> - BOM::User::Client instance

=back

=cut

sub get_new_account_currency {
    my ($client) = @_;

    my $available_currencies = $client->landing_company->available_trading_platform_currency_group->{ctrader} // [];
    my ($default_currency) = $available_currencies->@*;
    return $default_currency;
}

=head2 construct_group_name

Construct cTrader group name

=over 4

=item * C<market_type> - Market type, currently available type is "all"

=item * C<landing_company_short> - Short code representation of landing company. Example: "svg"

=item * C<currency> - Currency code

=back

=cut

sub construct_group_name {
    my ($market_type, $landing_company_short, $currency) = @_;
    my $group = join('_', ('ctrader', $market_type, $landing_company_short, 'std', lc $currency));

    return lc($group);
}

=head2 check_existing_account

Check if an existing active cTrader account already exists based on group and account type.

=over 4

=item * C<loginids> - List of existing cTrader account ids

=item * C<user> - BOM::User instance

=item * C<new_account_group> - The string value of the new account group

=item * C<account_type> - Account type can be "real" or "demo"

=back

=cut

sub check_existing_account {
    my ($loginids, $user, $new_account_group, $account_type) = @_;
    my $loginid_details                     = $user->loginid_details;
    my $ctrader_config                      = BOM::Config::ctrader_general_configurations();
    my $new_account_strategy_provider_group = $ctrader_config->{strategy_provider_group}->{$account_type . '_' . $new_account_group};
    my $max_accounts_limit                  = $ctrader_config->{new_account}->{max_accounts_limit}->{$account_type};
    my $existing_group_count                = 0;
    my $error_type;

    foreach my $loginid (@$loginids) {
        my $login_data                               = $loginid_details->{$loginid};
        my $existing_group                           = $login_data->{attributes}->{group};
        my $existing_account_type                    = $login_data->{account_type};
        my $existing_account_strategy_provider_group = $ctrader_config->{strategy_provider_group}->{$existing_account_type . '_' . $existing_group};

        # Skip if there's no group information
        next unless $login_data && $existing_group;

        if ($existing_account_strategy_provider_group eq $new_account_strategy_provider_group) {
            $existing_group_count++;

            if ($existing_group_count >= $max_accounts_limit) {
                $error_type = 'CTraderExistingAccountLimitExceeded';
                last;    # Stop the loop as the limit is exceeded
            }
        }
    }

    return {
        error  => $error_type,
        params => $max_accounts_limit
    } if $error_type;
}

=head2 construct_new_trader_params

Construct hash data in cTrader accepted format for new trader account creation.

=over 4

=item * C<client> - BOM::User::Client instance

=item * C<currency> - Currency code

=item * C<group> - Account group name

=item * C<environment> - live or demo

=back

=cut

sub construct_new_trader_params {
    my $params         = shift;
    my $client_details = _get_client_details($params->{client});

    return +{
        name            => delete $client_details->{name},
        lastName        => delete $client_details->{lastName},
        contactDetails  => $client_details,
        accessRights    => DEFAULT_ACCESS_RIGHTS,
        depositCurrency => uc $params->{currency},
        groupName       => $params->{group},
        hashedPassword  => _generate_hashpassword($params->{client}),
        leverageInCents => CTRADER_ALL_LEVERAGE,
        maxLeverage     => CTRADER_ALL_LEVERAGE,
        balance         => CTRADER_DEFAULT_BALANCE()->{$params->{environment}},
    };
}

=head2 group_to_groupid

Convert a given group name to its corresponding number representative

=over 4

=item * C<current_group> - Group name for the new account

=item * C<available_group> - List of valid group list obtain from cTrader API call

=back

=cut

sub group_to_groupid {
    my ($current_group, $available_group) = @_;

    foreach my $group (@$available_group) {
        return $group->{groupId} if $group->{name} eq $current_group;
    }

    return {error => 'CTraderInvalidGroup'};
}

=head2 is_valid_group

Check if given group name is accepted by cTrader

=over 4

=item * C<current_group> - Group name for the new account

=item * C<available_group> - List of valid group list obtain from cTrader API call

=back

=cut

sub is_valid_group {
    my ($current_group, $available_group) = @_;

    foreach my $group (@$available_group) {
        return 1 if $group->{name} eq $current_group;
    }

    return 0;
}

=head2 traderid_from_traderlightlist

Extract Trader account's trader id attached to its login id

=over 4

=item * C<trader_login> - Login id of trader account

=item * C<trader_lightlist> - List of traders' account

=back

=cut

sub traderid_from_traderlightlist {
    my ($trader_login, $trader_lightlist) = @_;

    foreach my $trader (@$trader_lightlist) {
        return $trader->{traderId} if $trader->{login} eq $trader_login;
    }

    return 0;
}

=head2 _generate_hashpassword

Generate hashpassword

=over 4

=item * C<client> - BOM::User::Client instance

=back

=cut

sub _generate_hashpassword {
    my $client       = shift;
    my $hashpassword = substr(sha384_hex($client->binary_user_id . 'E3xsTE6BQ=='), 0, 20);
    return $hashpassword . 'Hx_0';
}

=head2 get_ctrader_account_type

Retrieve cTrader account type

=over 4

=item * C<group_name> (String) - The group name for which you want to retrieve the cTrader account type.

=back

This subroutine allows you to retrieve a cTrader account type by providing the group name. It performs the following steps:

1. Converts the provided group name to lowercase for consistency.

2. Looks up the cTrader account type in the configuration using the lowercase group name.

Returns the cTrader account type associated with the provided group name as a scalar value. If no matching account type is found, it returns C<undef>.

=cut

sub get_ctrader_account_type {
    my ($group_name) = shift;

    my $group_accounttype = lc($group_name);

    return BOM::Config::ctrader_account_types()->{$group_accounttype};
}

1;
