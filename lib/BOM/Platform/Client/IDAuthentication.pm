package BOM::Platform::Client::IDAuthentication;

use Moose;

use namespace::autoclean;

use Brands;
use Client::Account;
use BOM::System::Config;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(localize request);
use BOM::Platform::ProveID;

has client => (
    is  => 'ro',
    isa => 'Client::Account'
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

    my $set_status = sub {
        my ($status, $reason, $description) = @_;
        $self->_notify($reason, $description);
        $client->set_status($status, 'system', $reason);
        $client->save;
    };

    # deceased or fraud => disable the client
    if ($prove_id_result->{deceased} or $prove_id_result->{fraud}) {
        my $key = $prove_id_result->{deceased} ? "deceased" : "fraud";
        $set_status->('disabled', 'PROVE ID INDICATES ' . uc($key), "Client was flagged as $key by Experian Prove ID check");
    }
    # we have a match, but result is DENY
    elsif ( $prove_id_result->{deny}
        and defined $prove_id_result->{matches}
        and (scalar @{$prove_id_result->{matches}} > 0))
    {
        my $type;
        # Office of Foreign Assets Control, HM Treasury => disable the client
        if (($type) = grep { /(OFAC|BOE)/ } @{$prove_id_result->{matches}}) {
            $set_status->('disabled', "$type match", "$type match");
        }
        # Director or Politically Exposed => unwelcome client
        elsif ((($type) = grep { /(PEP|Directors)/ } @{$prove_id_result->{matches}})) {
            $set_status->('unwelcome', "$type match", "$type match");
        } else {
            $set_status->('unwelcome', 'EXPERIAN PROVE ID RETURNED DENY', join(', ', @{$prove_id_result->{matches}}));
        }
    }
    # County Court Judgement => unwelcome client
    elsif ($prove_id_result->{CCJ}) {
        $set_status->('unwelcome', 'PROVE ID INDICATES CCJ', 'Client was flagged as CCJ by Experian Prove ID check');
    }
    # result is FULLY AUTHENTICATED => age verified as IOM GSC no longer accept Experian to authenticate clients
    elsif ($prove_id_result->{fully_authenticated}) {
        $set_status->('age_verification', 'EXPERIAN PROVE ID KYC PASSED ON FIRST DEPOSIT', 'passed PROVE ID KYC and is age verified');
    }
    # result is AGE VERIFIED ONLY
    elsif ($prove_id_result->{age_verified}) {
        $set_status->('age_verification', 'EXPERIAN PROVE ID KYC PASSED ONLY AGE VERIFICATION', 'could only get enough score for age verification.');
    }
    # no verifications => unwelcome client
    elsif (exists $prove_id_result->{num_verifications} and $prove_id_result->{num_verifications} eq 0) {
        $set_status->('unwelcome', 'PROVE ID INDICATES NO VERIFICATIONS', 'proveid indicates no verifications');
    }
    # failed to authenticate
    else {
        $set_status->('unwelcome', 'PROVEID_AUTH_FAILED', 'Failed to authenticate this user via PROVE ID through Experian');
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

    my $client_name = join(' ', $client->salutation, $client->first_name, $client->last_name);
    my $support_email = Brands->new(name => request()->brand)->emails('support');
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

    return unless BOM::System::Config::on_production();

    my $client = $self->client;
    $client->add_note($id, $client->loginid . ' ' . $msg);
    return;
}

sub _fetch_proveid {
    my $self = shift;

    return unless BOM::System::Config::on_production();

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
