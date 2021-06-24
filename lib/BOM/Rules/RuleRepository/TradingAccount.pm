package BOM::Rules::RuleRepository::TradingAccount;

=head1 NAME

BOM::Rules::RuleRepositry::trading_account

=head1 DESCRIPTION

This modules declares rules and regulations pertaining the trading accounts.

=cut

use strict;
use warnings;

use BOM::Platform::Context qw(request);
use BOM::Rules::Registry qw(rule);
use List::Util qw(none);

rule 'trading_account.should_match_landing_company' => {
    description => 'Checks whether there is a valid landing company account for the given trading account creation params',
    code        => sub {
        my ($self, $context, $args) = @_;

        # For now only svg and virtual are allowed
        my $client              = $context->client;
        my $market_type         = $args->{market_type} // '';
        my $user                = $client->user;
        my $residence           = $context->residence;
        my $countries_instance  = request()->brand->countries_instance;
        my $countries_list      = $countries_instance->countries_list;
        my $lc_type             = $market_type eq 'synthetic' ? 'gaming' : $market_type;
        my $binary_company_name = $countries_list->{$residence}->{"${lc_type}_company"} // '';

        # TODO: add some sort of LC entry for this.
        die_with_params(+{error_code => 'TradingAccountNotAllowed'}, $args) if $binary_company_name ne 'svg';

        my $account_type = $args->{account_type} // '';
        return 1 if $account_type eq 'demo';

        if ($client->landing_company->short ne $binary_company_name) {
            my @clients = $user->clients_for_landing_company($binary_company_name);
            @clients = grep { !$_->status->disabled && !$_->status->duplicate_account } @clients;
            $client  = (@clients > 0) ? $clients[0] : undef;
        }

        unless ($client) {
            die_with_params(+{error_code => 'RealAccountMissing'}, $args)
                if (scalar($user->clients) == 1 and $context->client->is_virtual());
            die_with_params(+{error_code => 'FinancialAccountMissing'}, $args) if $market_type eq 'financial';
            die_with_params(+{error_code => 'GamingAccountMissing'},    $args);
        }

        return 1;
    },
};

rule 'trading_account.should_be_age_verified' => {
    description => 'Checks whether the context client needs to be age verified',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $account_type = $args->{account_type} // '';
        return 1 if $account_type eq 'demo';

        my $config = request()->brand->countries_instance->countries_list->{$context->client->residence};

        if ($config->{trading_age_verification} and not $context->client->status->age_verification) {
            return ($context->client->is_virtual() and $context->client->user->clients == 1)
                ? die_with_params(+{error_code => 'RealAccountMissing'}, $args)
                : die_with_params(+{error_code => 'NoAgeVerification'},  $args);
        }

        return 1;
    },
};

rule 'trading_account.should_complete_financial_assessment' => {
    description => "Checks whether the context client should complete the financial assessment",
    code        => sub {
        my ($self, $context, $args) = @_;

        die_with_params(+{error_code => 'FinancialAssessmentMandatory'}, $args) unless $context->client->is_financial_assessment_complete();

        return 1;
    },
};

rule 'trading_account.should_provide_tax_details' => {
    description => "Checks whether the context client should provide tax details",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $countries_instance      = request()->brand->countries_instance;
        my $market_type             = $args->{market_type}      // '';
        my $sub_account_type        = $args->{sub_account_type} // '';
        my $residence               = $context->residence;
        my $company_name            = $context->client->landing_company->short;
        my $requirements            = LandingCompany::Registry->new->get($company_name)->requirements;
        my $compliance_requirements = $requirements->{compliance} // {};

        die_with_params(+{error_code => 'TINDetailsMandatory'}, $args)
            if ($compliance_requirements->{tax_information}
            and $countries_instance->is_tax_detail_mandatory($context->residence)
            and not $context->client->status->crs_tin_information);

        return 1;
    },
};

rule 'trading_account.client_should_be_real' => {
    description => 'Checks whether the context client is real',
    code        => sub {
        my ($self, $context, $args) = @_;

        die_with_params(+{error_code => 'AccountShouldBeReal'}, $args) if $context->client->is_virtual();

        return 1;
    },
};

rule 'trading_account.allowed_currency' => {
    description => 'Checks whether the given currency is allowed to open a trading account',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $currency         = $args->{currency} // '';
        my $trading_platform = $args->{platform} // '';

        # Gets the allowed currency from LC
        my $available_platforms = $context->client->landing_company->available_trading_platform_currency_group() // {};
        my $allowed_currencies  = $available_platforms->{$trading_platform}                                      // [];

        die_with_params(+{error_code => 'TradingAccountCurrencyNotAllowed'}, $args) if none { $_ eq $currency } $allowed_currencies->@*;

        return 1;
    },
};

=head2 die_with_params

Some error codes need the `message_params` hash to be filled.

It takes the following params:

=over 4

=item * C<$e> the exception hash to be thrown.

=item * C<$args> the arguments given to the rule. 

=back

Returns a hashref with the `message_params` if needed.

=cut

sub die_with_params {
    my ($e, $args) = @_;
    my $message_params = [];
    my $platform       = $args->{platform} // '';
    my $name;

    # TODO: someday when more platforms are added move this to a hash.
    $name = 'Deriv X' if $platform eq 'dxtrade';

    push $message_params->@*, $name if $name;

    $e->{message_params} = $message_params if scalar $message_params->@* > 0;

    die $e;
}

1;
