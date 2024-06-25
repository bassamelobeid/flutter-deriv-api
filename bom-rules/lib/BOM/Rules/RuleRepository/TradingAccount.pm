package BOM::Rules::RuleRepository::TradingAccount;

=head1 NAME

BOM::Rules::RuleRepositry::trading_account

=head1 DESCRIPTION

This modules declares rules and regulations pertaining the trading accounts.

=cut

use strict;
use warnings;

use LandingCompany::Registry;
use BOM::Rules::Registry   qw(rule);
use BOM::Platform::Context qw(request);
use List::Util             qw(any none);
use Business::Config::Account::Type::Registry;

rule 'trading_account.should_match_landing_company' => {
    description => 'Checks whether there is a valid landing company account for the given trading account creation params',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        my $market_type         = $args->{market_type} // '';
        my $user                = $client->user;
        my $residence           = $client->residence;
        my $countries_instance  = $context->brand($args)->countries_instance;
        my $countries_list      = $countries_instance->countries_list;
        my $lc_type             = $market_type eq 'synthetic' ? 'gaming' : $market_type;
        my %get_trading_company = (
            dxtrade => sub {
                $countries_instance->dx_company_for_country(
                    country      => $residence,
                    account_type => $lc_type
                );
            },
            ctrader => sub {
                $countries_instance->ctrader_company_for_country($residence);
            },
        );

        my $trading_company = $get_trading_company{$args->{platform}}->();

        die_with_params($self, 'TradingAccountNotAllowed', $args) if $trading_company eq 'none';

        my $account_type = $args->{account_type} // '';
        return 1 if $account_type eq 'demo' && $context->client($args)->is_virtual();

        if ($client->landing_company->short ne $trading_company) {
            die_with_params($self, 'RealAccountMissing', $args)
                if (scalar($user->clients) == 1 and $context->client($args)->is_virtual());
            die_with_params($self, 'AccountShouldBeReal',     $args) if $client->is_virtual();
            die_with_params($self, 'FinancialAccountMissing', $args) if $market_type eq 'financial';
            die_with_params($self, 'GamingAccountMissing',    $args);
        }

        return 1;
    },
};

rule 'trading_account.should_be_age_verified' => {
    description => 'Checks whether the context client needs to be age verified',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client       = $context->client($args);
        my $account_type = $args->{account_type} // '';
        return 1 if $account_type eq 'demo';

        my $config = $context->get_country_legacy($client->residence);

        if ($config->{trading_age_verification} and not $client->status->age_verification) {
            return ($client->is_virtual() and $client->user->clients == 1)
                ? die_with_params($self, 'RealAccountMissing', $args)
                : die_with_params($self, 'NoAgeVerification',  $args);
        }

        return 1;
    },
};

rule 'trading_account.should_complete_financial_assessment' => {
    description => "Checks whether the context client should complete the financial assessment",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        die_with_params($self, 'FinancialAssessmentMandatory', $args) unless $client->is_financial_assessment_complete();

        return 1;
    },
};

rule 'trading_account.should_provide_tax_details' => {
    description => "Checks whether the context client should provide tax details",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        my $countries_instance      = $context->brand($args)->countries_instance;
        my $market_type             = $args->{market_type}      // '';
        my $sub_account_type        = $args->{sub_account_type} // '';
        my $residence               = $client->residence;
        my $company_name            = $client->landing_company->short;
        my $requirements            = LandingCompany::Registry->by_name($company_name)->requirements;
        my $compliance_requirements = $requirements->{compliance} // {};

        die_with_params($self, 'TINDetailsMandatory', $args)
            if ($compliance_requirements->{tax_information}
            and $countries_instance->is_tax_detail_mandatory($residence)
            and not $client->status->crs_tin_information);

        return 1;
    },
};

rule 'trading_account.client_should_be_real' => {
    description => 'Checks whether the context client is real',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        die_with_params($self, 'AccountShouldBeReal', $args) if $client->is_virtual();

        return 1;
    },
};

rule 'trading_account.client_account_type_should_be_supported' => {
    description => '',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        my $account_type = $context->client($args)->get_account_type->name;

        # Legacy flow
        return 1 if $account_type eq 'binary';

        # Wallet flow
        my $platform_account_type = Business::Config::Account::Type::Registry->new()->account_type_by_name($args->{platform});
        return 1 if any { $_ eq $account_type } $platform_account_type->linkable_wallet_types->@*;

        return die_with_params($self, 'TradingPlatformInvalidAccount', $args);
    },
};

rule 'trading_account.trading_platform_supported_by_residence_and_regulation' => {
    description => '',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        my $regulation           = $args->{account_type} eq 'demo' ? 'virtual' : $args->{regulation};
        my $derivez_account_type = Business::Config::Account::Type::Registry->new()->account_type_by_name($args->{platform});

        my $is_supported = $derivez_account_type->is_supported($client->residence, $regulation);

        return 1 if $is_supported;

        return die_with_params($self, 'TradingPlatformInvalidAccount', $args);
    },
};

rule 'trading_account.client_should_be_legacy_or_virtual_wallet' => {
    description => 'Checks whether the context client is legacy or virtual wallet',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $account_type = $context->client($args)->get_account_type;

        $self->fail('TradingPlatformInvalidAccount')
            if $account_type->name ne 'binary'      # Legacy Flow
            && $account_type->name ne 'virtual';    # Wallet flow

        return 1;
    },
};

rule 'trading_account.allowed_currency' => {
    description => 'Checks whether the given currency is allowed to open a trading account',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client           = $context->client($args);
        my $currency         = $args->{currency} // '';
        my $trading_platform = $args->{platform} // '';

        # Gets the allowed currency from LC
        my $available_platforms = $client->landing_company->available_trading_platform_currency_group() // {};
        my $allowed_currencies  = $available_platforms->{$trading_platform}                             // [];

        die_with_params($self, 'TradingAccountCurrencyNotAllowed', $args) if none { $_ eq $currency } $allowed_currencies->@*;

        return 1;
    },
};

rule 'trading_account.client_support_account_creation' => {
    description => 'Checks that trading platform creation is available for current client account',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client           = $context->client($args);
        my $trading_platform = $args->{platform} // '';

        if (!$client->is_wallet) {
            return 1 if $client->is_legacy;
            return $self->fail('PermissionDenied');
        }

        my $trading_platform_type = Business::Config::Account::Type::Registry->new()->account_type_by_name($trading_platform);
        my @supported_types       = $trading_platform_type->linkable_wallet_types->@*;

        my $account_type = $client->get_account_type;
        for my $type (@supported_types) {
            return 1 if $type eq $account_type->name;
        }

        return $self->fail('PermissionDenied');
    }
};

=head2 die_with_params

Some error codes need the `message_params` hash to be filled.

It takes the following params:

=over 4

=item * C<$code> the error code.

=item * C<$args> the arguments given to the rule.

=back

Returns a hashref with the `message_params` if needed.

=cut

sub die_with_params {
    my ($self, $code, $args) = @_;
    my @params;
    my $platform = $args->{platform} // '';

    my $name = +{
        dxtrade => 'Deriv X',
        derivez => 'DerivEZ',
        mt5     => 'MT5',
        ctrader => 'cTrader',
    }->{$platform};

    push @params, $name if $name;

    $self->fail($code, @params ? (params => \@params) : (),);
}

1;
