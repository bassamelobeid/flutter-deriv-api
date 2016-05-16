package BOM::Platform::Client::IDAuthentication;

use Moose;

use namespace::autoclean;

use BOM::Platform::Email qw(send_email);
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Client;
use BOM::Platform::ProveID;
use BOM::Platform::Static::Config;

has client => (
    is  => 'ro',
    isa => 'BOM::Platform::Client'
);

has force_recheck => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0
);

sub run_authentication {
    my $self   = shift;
    my $client = $self->client;

    return if $client->is_virtual;

    # Binary Investment clients should already be fully_authenticated by the time this code runs following an intial deposit.
    # Binary Investment accounts are set to "unwelcome" when they are first created.  Document
    # submission is REQUIRED before the account is enabled for use

    return if $client->client_fully_authenticated || $client->landing_company->short eq 'maltainvest';

    # any of these callouts might invoke _request_id_authentication which
    # will return a structure suitable for passing to a mailer.

    my $envelope;

    if ($client->landing_company->country eq 'Isle of Man') {
        $envelope = $self->_do_proveid;
    } elsif ($client->landing_company->country ne 'Costa Rica'
        && !$client->get_status('age_verification')
        && !$client->has_valid_documents)
    {
        $envelope = $self->_request_id_authentication;
    }

    send_email($envelope) if $envelope;
    return;
}

sub _do_proveid {
    my $self   = shift;
    my $client = $self->client;

    my $prove_id_result = $self->_fetch_proveid || {};

    # deceased or fraud => disable the client
    if ($prove_id_result->{deceased} or $prove_id_result->{fraud}) {
        my $reason = $prove_id_result->{deceased} ? "deceased" : "fraud";
        $self->_notify('PROVE ID INDICATES ' . uc($reason), "Client was flagged as $reason by Experian Prove ID check");
        $client->set_status('disabled', 'system', 'PROVE ID INDICATES ' . uc($reason));
        $client->save;
    }
    # we have a match, but result is DENY
    elsif ( $prove_id_result->{deny}
        and defined $prove_id_result->{matches}
        and (scalar @{$prove_id_result->{matches}} > 0))
    {
        if (grep { /(PEP|OFAC|BOE)/ } @{$prove_id_result->{matches}}) {
            my $type = $1;
            $self->_notify("$1 match", "$1 match");
            $client->set_status('disabled', 'system', "$1 match");
            $client->save;
        } else {
            $self->_notify('EXPERIAN PROVE ID RETURNED DENY ', join(', ', @{$prove_id_result->{matches}}));
            $client->set_status('unwelcome', 'system', 'Experian returned DENY');
            $client->save();
        }
    }
    # result is FULLY AUTHENTICATED
    elsif ($prove_id_result->{fully_authenticated}) {
        $self->_notify('EXPERIAN PROVE ID KYC PASSED ON FIRST DEPOSIT', 'passed PROVE ID KYC and is fully authenticated.');
        $client->set_status('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID');
        # $client->set_authentication('ID_192')->status('pass'); #The IOM GSC no longer accept Experian to authenticate clients
        $client->save;
    }
    # result is AGE VERIFIED ONLY
    elsif ($prove_id_result->{age_verified}) {
        $self->_notify('EXPERIAN PROVE ID KYC PASSED ONLY AGE VERIFICATION', 'could only get enough score for age verification.');
        $client->set_status('age_verification', 'system', 'Successfully age verified via Experian Prove ID');
        $client->save;
    }
    # failed to authenticate
    else {
        $self->_notify('192_PROVEID_AUTH_FAILED', 'Failed to authenticate this user via PROVE ID through Experian');
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

    my $client_name   = join(' ', $client->salutation, $client->first_name, $client->last_name);
    my $support_email = BOM::Platform::Static::Config::get_customer_support_email();
    my $ce_subject    = localize('Documents are required to verify your identity');
    my $ce_body       = localize(<<'EOM', $client_name, $support_email);
Dear [_1],

We are writing to you regarding your account with Binary.com.

We are legally required to verify that clients are over the age of 18, and so we request that you forward scanned copies of one of the following to [_2]:

- Valid Passport or Driving licence or National ID card

In order to comply with licencing regulations, you will be unable to make further deposits or withdrawals or to trade on the account until we receive this document.

We look forward to hearing from you soon.

Kind regards,

Binary
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

sub _fetch_proveid {
    my $self = shift;

    return unless BOM::Platform::Runtime->instance->app_config->system->on_production;

    my $premise = $self->client->address_1;
    if ($premise =~ /^(\d+)/) {
        $premise = $1;
    }

    return BOM::Platform::ProveID->new(
        client        => $self->client,
        search_option => 'ProveID_KYC',
        premise       => $premise,
        force_recheck => $self->force_recheck
    )->get_result;
}

__PACKAGE__->meta->make_immutable;
1;
