package BOM::Rules::RuleRepository::Residence;

=head1 NAME

BOM::Rules::RuleRepositry::Residence

=head1 DESCRIPTION

This modules declares rules and regulations concerning the context residence.

=cut

use strict;
use warnings;

use List::Util;

use BOM::Rules::Registry qw(rule);

rule 'residence.market_type_is_available' => {
    description => "The market_type in args should be allowed in the context residence",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $market_type     = $args->{market_type}  // '';
        my $account_type    = $args->{account_type} // '';
        my $residence       = $context->residence($args);
        my $landing_company = $context->landing_company_object($args);

        my $countries_instance = $context->brand($args)->countries_instance;

        my $companies = {
            synthetic => $countries_instance->gaming_company_for_country($context->residence($args)),
            financial => $countries_instance->financial_company_for_country($context->residence($args)),
        };

        if ($account_type eq 'wallet' || $account_type eq 'affiliate') {
            $self->fail('InvalidAccount') unless List::Util::any { $_ } values %$companies;
        } else {
            $self->fail('InvalidAccount') if $context->landing_company($args) ne ($companies->{$market_type} // '');
        }

        return 1;
    },
};

rule 'residence.is_signup_allowed' => {
    description => "Checks if signup is allowed in the country of residence",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $residence = $context->residence($args);

        my $countries_instance = $context->brand($args)->countries_instance;

        $self->fail('InvalidAccount') unless $countries_instance->is_signup_allowed($residence);

        return 1;
    },
};

rule 'residence.account_type_is_available_for_real_account_opening' => {
    description => "Checks if the requested account type is enabled in the country of residence configuration.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $residence = $context->residence($args);

        die 'Account type is required' unless $args->{account_type};
        return 1 if $args->{account_type} eq 'trading';
        return 1 if $args->{account_type} eq 'affiliate';

        my $countries_instance = $context->brand($args)->countries_instance;

        my $wallet_lc_name = $countries_instance->wallet_company_for_country($residence, 'real') // 'none';

        $self->fail('InvalidResidence') if $wallet_lc_name eq 'none';

        return 1;
    },
};

rule 'residence.not_restricted' => {
    description => 'Fails if the context residence is restricted; succeeds otherwise',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $residence = $context->residence($args);

        my $countries_instance = $context->brand($args)->countries_instance;

        $self->fail('InvalidResidence') if $countries_instance->restricted_country($residence);

        return 1;
    },
};
