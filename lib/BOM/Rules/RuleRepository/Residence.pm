package BOM::Rules::RuleRepository::Residence;

=head1 NAME

BOM::Rules::RuleRepositry::Residence

=head1 DESCRIPTION

This modules declares rules and regulations concerning the context residence.

=cut

use strict;
use warnings;

use List::Util qw(any);

use BOM::Rules::Registry qw(rule);
use BOM::Config::AccountType;

rule 'residence.account_type_is_available' => {
    description => "The market_type in args should be allowed in the context residence",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $account_type = BOM::Config::AccountType::Registry->account_type_by_name($args->{account_type} // BOM::Config::AccountType::LEGACY_TYPE);

        $self->fail('InvalidAccount')
            unless $account_type->is_supported($context->brand($args), $context->residence($args), $context->landing_company($args));

        if ($account_type->name eq 'standard') {
            my $wallet      = $context->client($args);
            my $wallet_type = $wallet->get_account_type->name;

            return $self->fail('InvalidAccount') unless any { $_ eq $wallet_type } $account_type->linkable_wallet_types->@*;

            my @account_links = ($wallet->user->get_accounts_links->{$wallet->loginid} // [])->@*;

            for my $account_link (@account_links) {
                next if $account_link->{platform} ne $account_type->platform;

                my $sibling = BOM::User::Client->new({loginid => $account_link->{loginid}});

                # At least for now we're planning to allow only one Deriv trading account per type linked to the same wallet
                # In future we may introduce more.. but i hope we'll be introducing separate account types for those
                next if $sibling->get_account_type->name ne $account_type->name;

                # skip closed accounts
                next if $sibling->status->duplicate_account;

                return $self->fail('InvalidAccount');
            }
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
        my $residence       = $context->residence($args);
        my $landing_company = $context->landing_company($args);

        die 'Account type is required' unless $args->{account_type};
        return 1 if $args->{account_type} eq 'binary';
        return 1 if $args->{account_type} eq 'affiliate';
        return 1 if $args->{account_type} eq 'standard';

        my $countries_instance           = $context->brand($args)->countries_instance;
        my $wallet_companies_for_country = $countries_instance->wallet_companies_for_country($residence, 'real') // [];
        $self->fail('InvalidResidence')
            unless grep { $_ eq $landing_company } $wallet_companies_for_country->@*;
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
