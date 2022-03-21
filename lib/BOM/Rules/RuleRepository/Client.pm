package BOM::Rules::RuleRepository::Client;

=head1 NAME

BOM::Rules::RuleRepositry::Client

=head1 DESCRIPTION

Contains rules pertaining the context client.

=cut

use strict;
use warnings;

use BOM::Rules::Registry qw(rule);
use BOM::Config::Runtime;
use BOM::Config::CurrencyConfig;

rule 'client.check_duplicate_account' => {
    description => "Performs a duplicate check on the target client and the action args",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('DuplicateAccount') if $context->client($args)->check_duplicate_account($args);

        return 1;
    },
};

rule 'client.has_currency_set' => {
    description => 'Checks whether the target client has its currency set',
    code        => sub {
        my ($self, $context, $args) = @_;

        my $account = $context->client($args)->account;
        my $currency_code;

        $currency_code = $account->currency_code if $account;

        $self->fail('SetExistingAccountCurrency', params => $args->{loginid}) unless $currency_code;

        return 1;
    },
};

rule 'client.residence_is_not_empty' => {
    description => "fails if the target client's residence is not set yet.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('NoResidence') unless $context->client($args)->residence;

        return 1;
    },
};

# TODO: it's copied from bom-platform unchanged; but it should be removed in favor of client.immutable_fields
rule 'client.signup_immitable_fields_not_changed' => {
    description => "fails if any of the values of signup immutable fields are changed in the args.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->get_real_sibling($args);

        return 1 if $client->is_virtual;

        my @changed;
        for my $field (qw /citizen place_of_birth residence/) {
            next unless $client->$field and exists $args->{$field};

            push(@changed, $field) if $client->$field ne ($args->{$field} // '');
        }

        $self->fail('CannotChangeAccountDetails', details => {changed => [@changed]}) if @changed;

        return 1;
    },
};

rule 'client.is_not_virtual' => {
    description => 'It dies with a permission error if the target client is virtual; succeeds otherwise.',
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('PermissionDenied') if $context->client($args)->is_virtual;

        return 1;
    }
};

rule 'client.forbidden_postcodes' => {
    description => "Checks if postalcode is not allowed",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client                     = $context->client($args);
        my $forbidden_postcode_pattern = $context->get_country($client->residence)->{forbidden_postcode_pattern};
        my $postcode                   = $args->{address_postcode} // $client->address_postcode;

        $self->fail('ForbiddenPostcode') if (defined $forbidden_postcode_pattern && $postcode =~ /$forbidden_postcode_pattern/i);

        return 1;
    },
};

rule 'client.not_disabled' => {
    description => 'It dies if client is disabled, passes otherwise.',
    code        => sub {
        my ($self, $context, $args) = @_;
        $self->fail('DisabledAccount', params => [$args->{loginid}]) if $context->client($args)->status->disabled;

        return 1;
    }
};

rule 'client.documents_not_expired' => {
    description => "It dies if client's POI documents are expired.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('DocumentsExpired') if $context->client($args)->documents->expired;

        return 1;
    }
};

rule 'client.fully_authenticated' => {
    description => "Checks if client is fully authenticated (POI and POA).",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('NotAuthenticated') unless $context->client($args)->fully_authenticated;

        return 1;
    }
};

rule 'client.financial_risk_approval_status' => {
    description => "Checks if client has approved financial risks.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('FinancialRiskNotApproved') unless $context->client($args)->status->financial_risk_approval;

        return 1;
    }
};

rule 'client.crs_tax_information_status' => {
    description => "Checks if client has tax information status.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('NoTaxInformation') unless $context->client($args)->status->crs_tin_information;

        return 1;
    }
};

rule 'client.check_max_turnover_limit' => {
    description => "Checks if max turnover limits (and ukgc funds protection) are not missing if they are required.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);
        my $config = $context->brand($args)->countries_instance->countries_list->{$client->residence};

        return 1 unless ($config->{need_set_max_turnover_limit} || $client->landing_company->check_max_turnover_limit_is_set);

        $self->fail('NoUkgcFundsProtection') if $config->{ukgc_funds_protection} && !$client->status->ukgc_funds_protection;
        $self->fail('NoMaxTuroverLimit')     if $client->status->max_turnover_limit_not_set;

        return 1;
    }
};

rule 'client.no_unwelcome_status' => {
    description => "Fails if client is marked by unwelcome status.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('UnwelcomeStatus', params => [$args->{loginid}]) if $context->client($args)->status->unwelcome;

        return 1;
    }
};

rule 'client.no_withdrawal_or_trading_lock_status' => {
    description => "Fails if client is marked by no_withdrawal_or_trading status.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('NoWithdrawalOrTradingStatus') if $context->client($args)->status->no_withdrawal_or_trading;

        return 1;
    }
};

rule 'client.no_withdrawal_locked_status' => {
    description => "Fails if client is marked by withdrawal lock status.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('WithdrawalLockedStatus') if $context->client($args)->status->withdrawal_locked;

        return 1;
    }
};

rule 'client.high_risk_authenticated' => {
    description => "Fails if client is high risk, without authentication.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        $self->fail('HighRiskNotAuthenticated')
            if $client->risk_level eq 'high' and not $client->fully_authenticated;

        return 1;
    }
};

rule 'client.potential_fraud_age_verified' => {
    description => "Fails if client is potential fraud and POI is not done yet.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        $self->fail('PotentialFraud')
            if $client->status->potential_fraud and not $client->status->age_verification;

        return 1;
    }
};

1;
