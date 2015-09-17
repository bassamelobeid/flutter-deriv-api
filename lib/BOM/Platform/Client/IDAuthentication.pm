package BOM::Platform::Client::IDAuthentication;

use Moose;

use namespace::autoclean;

use BOM::Platform::Email qw(send_email);
use BOM::Database::Model::Constants;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Client;
use BOM::Platform::ProveID;

has client => (
    is  => 'ro',
    isa => 'BOM::Platform::Client'
);

has force_recheck => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0
);

sub _landing_company_country {
    my $self = shift;
    return $self->client->landing_company->country;
}

sub _needs_proveid {
    my $self = shift;

    my $landing_company_country = $self->_landing_company_country;

    # All MX clients needs authentication
    if ($landing_company_country eq 'Isle of Man') {
        return 1;
    }
    return;
}

sub _needs_checkid {
    my $self   = shift;
    my $client = $self->client;
    return unless $self->_landing_company_country eq 'Malta';
    return BOM::Platform::ProveID->valid_country($client->residence);
}

sub _requires_age_verified {
    my $self = shift;

    return if $self->client->is_virtual;
    return $self->_landing_company_country ne 'Costa Rica';
}

sub run_authentication {
    my $self   = shift;
    my $client = $self->client;
    return if $client->landing_company->short eq 'maltainvest'|| $client->client_fully_authenticated;

    # any of these callouts might invoke _request_id_authentication which
    # will return a structure suitable for passing to a mailer.

    my $envelope;

    if ($self->_needs_proveid) {

        $envelope = $self->_do_proveid

    } elsif ($self->_needs_checkid) {

        $envelope = $self->_do_checkid

    } elsif ($self->_requires_age_verified
        && !$client->get_status('age_verification')
        && !$client->has_valid_documents)
    {

        $envelope = $self->_request_id_authentication

    }

    send_email($envelope) if $envelope;
    return;
}

sub _do_proveid {
    my $self   = shift;
    my $client = $self->client;

    my $prove_id_result = $self->_fetch_proveid || {};

    if ($prove_id_result->{age_verified}) {
        $client->set_status('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID');
        $client->save;
        $prove_id_result->{matches} ||= [];

        if ($prove_id_result->{deny} or scalar @{$prove_id_result->{matches}}) {
            $self->_notify('EXPERIAN PROVE ID KYC PASSED BUT CLIENT FLAGGED!', 'flagged as [' . join(', ', @{$prove_id_result->{matches}}) . '] .');
        } elsif ($prove_id_result->{fully_authenticated}) {
            $client->set_status('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID');
            $client->set_authentication('ID_192')->status('pass');
            $client->save;

            $self->_notify('EXPERIAN PROVE ID KYC PASSED ON FIRST DEPOSIT', 'passed PROVE ID KYC on first deposit and is fully authenticated.');
        } else {
            $self->_notify('EXPERIAN PROVE ID KYC PASSED ONLY AGE VERIFICATION', 'could only get enough score for age verification.');
        }
    } else {
        $self->_notify('192_PROVEID_AUTH_FAILED', 'Failed to authenticate this user via PROVE ID through Experian');
        return $self->_request_id_authentication;
    }
    return;
}

sub _do_checkid {
    my $self   = shift;
    my $client = $self->client;

    if ($self->_fetch_checkid) {
        $client->set_status('age_verification', 'system', 'Successfully authenticated identity via Experian CHECK ID');
        $client->save;
        $self->_notify('EXPERIAN CHECK ID PASSED ON FIRST DEPOSIT', 'passed CHECK ID on first deposit.');
    } else {
        $self->_notify('192_CHECKID_AUTH_FAILED', 'failed to authenticate via CHECK ID through Experian');
        return $self->_request_id_authentication;
    }
    return;
}

sub _request_id_authentication {
    my $self   = shift;
    my $client = $self->client;
    my $status = 'cashier_locked';

    $client->set_status($status, 'system', 'Experian id authentication failed on first deposit');
    $client->save;
    $status = uc($status);
    $self->_notify("SET TO $status PENDING EMAIL REQUEST FOR ID", 'client received an email requesting identity proof');

    my $client_name    = join(' ', $client->salutation, $client->first_name, $client->last_name);
    my $support_email  = BOM::Platform::Context::request()->website->config->get('customer_support.email');
    my $ce_broker_name = BOM::Platform::Runtime->instance->website_list->get_by_broker_code($client->broker)->name;
    my $ce_subject     = localize('Documents are required to verify your identity');
    my $ce_body        = localize(<<'EOM', $client_name, $ce_broker_name, $support_email);
Dear [_1],

I am writing to you regarding your account with Binary.com.

We are legally required to verify that clients are over the age of 18, and so we request that you forward scanned copies of one of the following to helpdesk@binary.com:

- Valid Passport or Driving licence or National ID card

In order to comply with licencing regulations, you will be unable to make further deposits or withdrawals or to trade on the account until we receive this document.

I look forward to hearing from you soon.

Kind regards,

[_2]
EOM
    return ({
        from               => $support_email,
        to                 => $client->email,
        subject            => $ce_subject,
        message            => [$ce_body],
        use_email_template => 1,
        template_loginid   => $client->loginid,
    });
}

sub _notify {
    my ($self, $id, $msg) = @_;

    return unless BOM::Platform::Runtime->instance->app_config->system->on_production;

    my $client = $self->client;
    $client->add_note($id, $client->loginid . ' ' . $msg);
    return;
}

sub _premise {
    my $self    = shift;
    my $premise = $self->client->address_1;
    if ($premise =~ /^(\d+)/) {
        $premise = $1;
    }
    return $premise;
}

sub _fetch_proveid {
    my $self = shift;

    return unless BOM::Platform::Runtime->instance->app_config->system->on_production;

    return BOM::Platform::ProveID->new(
        client        => $self->client,
        search_option => 'ProveID_KYC',
        premise       => $self->_premise,
        force_recheck => $self->force_recheck
    )->get_result;
}

sub _fetch_checkid {
    my $self = shift;

    return unless BOM::Platform::Runtime->instance->app_config->system->on_production;

    return BOM::Platform::ProveID->new(
        client        => $self->client,
        search_option => 'CheckID',
        premise       => $self->_premise,
        force_recheck => $self->force_recheck
    )->get_result;
}

__PACKAGE__->meta->make_immutable;
1;
