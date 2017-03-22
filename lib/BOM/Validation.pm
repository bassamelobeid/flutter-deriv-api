package BOM::Validation;

use strict;
use warnings;

use Moo;

has client => (
    is       => 'ro',
    required => 1
);
has transaction => (
    is       => 'ro',
    required => 0
);

sub validate_tnc {
    my $self = shift;

    # we shouldn't get to this error, so we can die it directly
    return 1 if $self->client->is_virtual;

    my $current_tnc_version = BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version;
    my $client_tnc_status   = $self->client->get_status('tnc_approval');
    return if not $client_tnc_status or ($client_tnc_status->reason ne $current_tnc_version);
}

sub compliance_checks {
    my $self = shift;

    # checks are not applicable for virtual, costarica and champion clients
    return 1 if $self->client->is_virtual;
    return 1 if $self->client->landing_company->short =~ /^(?:costarica|champion)$/;

    # as per compliance for high risk client we need to check
    # if financial assessment details are completed or not
    return if ($self->client->aml_risk_classification // '') eq 'high' and not $self->client->financial_assessment();

    return 1;
}

sub check_tax_information {
    my $self = shift;

    return if $self->client->landing_company->short eq 'maltainvest' and not $self->client->get_status('crs_tin_information');

    return 1;
}

# don't allow to trade for unwelcome_clients
# and for MLT and MX we don't allow trading without confirmed age
sub check_trade_status {
    my $self = shift;

    return 1 if $self->client->is_virtual;
    return 1 if $self->allow_trade;

    return undef;
}

=head2 allow_paymentagent_withdrawal

to check client can withdrawal through payment agent. return 1 (allow) or undef (denied)

=cut

sub allow_paymentagent_withdrawal {
    my $self = shift;

    my $expires_on = $self->client->payment_agent_withdrawal_expiration_date;

    if ($expires_on) {
        # if expiry date is in future it means it has been validated hence allowed
        return 1 if Date::Utility->new($expires_on)->is_after(Date::Utility->new);
    } else {
        # if expiry date is not set check for doughflow count
        my $payment_mapper = BOM::Database::DataMapper::Payment->new({'client_loginid' => $self->client->loginid});
        my $doughflow_count = $payment_mapper->get_client_payment_count_by({payment_gateway_code => 'doughflow'});
        return 1 if $doughflow_count == 0;
    }

    return;
}

=head2 allow_trade

Check if client is allowed to trade.

Don't allow to trade for unwelcome_clients and for MLT and MX without confirmed age

=cut

sub allow_trade {
    my $self = shift;

    return
            if ($self->client->landing_company->short =~ /^(?:malta|iom)$/)
        and not $self->client->get_status('age_verification')
        and $self->client->has_deposits;
    return if $self->client->get_status('unwelcome');
    return 1;
}

1;
