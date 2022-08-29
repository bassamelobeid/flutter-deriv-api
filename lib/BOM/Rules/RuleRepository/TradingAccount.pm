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
use List::Util             qw(none);

rule 'trading_account.should_match_landing_company' => {
    description => 'Checks whether there is a valid landing company account for the given trading account creation params',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        my $market_type        = $args->{market_type} // '';
        my $user               = $client->user;
        my $residence          = $client->residence;
        my $countries_instance = $context->brand($args)->countries_instance;
        my $countries_list     = $countries_instance->countries_list;
        my $lc_type            = $market_type eq 'synthetic' ? 'gaming' : $market_type;

        my $dx_company = $countries_instance->dx_company_for_country(
            country      => $residence,
            account_type => $lc_type
        );

        die_with_params($self, 'TradingAccountNotAllowed', $args) if $dx_company eq 'none';

        my $account_type = $args->{account_type} // '';
        return 1 if $account_type eq 'demo';

        if ($client->landing_company->short ne $dx_company) {
            my @clients = $user->clients_for_landing_company($dx_company);
            ($client) = grep { !$_->status->disabled && !$_->status->duplicate_account } @clients;
        }

        unless ($client) {
            die_with_params($self, 'RealAccountMissing', $args)
                if (scalar($user->clients) == 1 and $context->client($args)->is_virtual());
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

        my $config = $context->get_country($client->residence);

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
    my @message_params;
    my $platform = $args->{platform} // '';
    my $name;

    # TODO: someday when more platforms are added move this to a hash.
    $name = 'Deriv X' if $platform eq 'dxtrade';

    push @message_params, $name if $name;

    $self->fail($code, @message_params ? (message_params => \@message_params) : (),);
}

1;
