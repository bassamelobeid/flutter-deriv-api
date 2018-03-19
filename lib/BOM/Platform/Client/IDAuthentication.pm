package BOM::Platform::Client::IDAuthentication;

use Moose;
use namespace::autoclean;
use Try::Tiny;

use Brands;
use BOM::User::Client;
use BOM::Platform::Config;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(localize request);
use BOM::Platform::ProveID;

has client => (
    is  => 'ro',
    isa => 'BOM::User::Client'
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
    my $landing_company;
    return if $client->client_fully_authenticated || ($landing_company = $client->landing_company->short) eq 'maltainvest';

    # any of these callouts might invoke _request_id_authentication which
    # will return a structure suitable for passing to a mailer.
    my $envelope;
    if ($landing_company eq 'iom') {
        $envelope = $self->_do_proveid;
    } elsif ($landing_company eq 'malta'
        && !$client->get_status('age_verification')
        && !$client->has_valid_documents)
    {
        $envelope = $self->_request_id_authentication;
    }

    send_email($envelope) if $envelope;
    return;
}

#
# All logic in _do_proveid meet compliance requirements, which can be changed over time
#
sub _do_proveid {
    my $self   = shift;
    my $client = $self->client;

    my $prove_id_result = $self->_fetch_proveid || {};
    my $skip_request_for_id;

    my $set_status = sub {
        my ($status, $reason, $description) = @_;
        $self->_notify($reason, $description) if $status ne 'age_verification';
        $client->set_status($status, 'system', $reason);
        $client->save;
    };

    # deceased or fraud => disable the client
    if ($prove_id_result->{deceased} or $prove_id_result->{fraud}) {
        my $key = $prove_id_result->{deceased} ? "deceased" : "fraud";
        $set_status->('disabled', 'PROVE ID INDICATES ' . uc($key), "Client was flagged as $key by Experian Prove ID check");
        $skip_request_for_id = 1;
    }
    # we have a match, handle it
    elsif (defined $prove_id_result->{matches}
        and (scalar @{$prove_id_result->{matches}} > 0))
    {
        my $type;
        # Office of Foreign Assets Control, HM Treasury => disable the client
        if (($type) = grep { /(OFAC|BOE)/ } @{$prove_id_result->{matches}}) {
            $set_status->('disabled', "$type match", "$type match");
        }
        # Director is ok, no unwelcome, no documents request
        elsif (grep { /Directors/ } @{$prove_id_result->{matches}}) {
        }
        # Politically Exposed => unwelcome client
        elsif ((($type) = grep { /(PEP)/ } @{$prove_id_result->{matches}})) {
            $set_status->('unwelcome', "$type match", "$type match");
        } else {
            $set_status->('unwelcome', 'EXPERIAN PROVE ID RETURNED MATCH', join(', ', @{$prove_id_result->{matches}}));
        }
        $skip_request_for_id = 1;
    }
    # County Court Judgement is ok, no unwelcome, no documents request
    elsif ($prove_id_result->{CCJ}) {
        $skip_request_for_id = 1;
    }
    # result is AGE VERIFIED ONLY
    if ($prove_id_result->{age_verified}) {
        $set_status->('age_verification', 'EXPERIAN PROVE ID KYC PASSED AGE VERIFICATION', 'could get enough score for age verification.');
        $skip_request_for_id = 1;
    }

    # unwelcome status will be set up there
    return $self->_request_id_authentication unless $skip_request_for_id;

    return;
}

sub _request_id_authentication {
    my $self   = shift;
    my $client = $self->client;
    my $status = 'cashier_locked';

    # special case for MX: forbid them to trade before age_verified. cashier_locked enables to trade
    $status = "unwelcome" if $client->landing_company->short eq 'iom';

    $client->set_status($status, 'system', 'Experian id authentication failed on first deposit');
    $client->save;

    my $client_name = join(' ', $client->salutation, $client->first_name, $client->last_name);
    my $brand         = Brands->new(name => request()->brand);
    my $support_email = $brand->emails('support');
    my $ce_subject    = localize('Documents are required to verify your identity');
    my $ce_body       = localize(<<'EOM', $client_name, $brand->website_name, $support_email);
Dear [_1],

We are writing to you regarding your account with [_2].

We are legally required to verify that clients are over the age of 18, and so we request that you forward scanned copies of one of the following to [_3]:

- Valid Passport or Driving licence or National ID card

In order to comply with licencing regulations, you will be unable to make further deposits or withdrawals or to trade on the account until we receive this document.

We look forward to hearing from you soon.

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

    return unless BOM::Platform::Config::on_production();

    my $client = $self->client;
    $client->add_note($id, $client->loginid . ' ' . $msg);
    return;
}

sub _fetch_proveid {
    my $self = shift;

    return unless BOM::Platform::Config::on_production();

    my $premise = $self->client->address_1;
    if ($premise =~ /^(\d+)/) {
        $premise = $1;
    }
    my $result = {};
    try {
        $result = BOM::Platform::ProveID->new(
            client        => $self->client,
            search_option => 'ProveID_KYC',
            premise       => $premise,
            force_recheck => $self->force_recheck
        )->get_result;
    }
    catch {
        my $brand    = Brands->new(name => request()->brand);
        my $clientid = $self->client->loginid;
        my $message  = <<EOM;
There was an error during Experian request.
Error is: $_
Client: $clientid
EOM
        warn "Experian error in _fetch_proveid: ", $_;
        send_email({
            from    => $brand->emails('compliance'),
            to      => $brand->emails('compliance'),
            subject => 'Experian request error',
            message => [$message],
        });
    };
    return $result;
}

__PACKAGE__->meta->make_immutable;
1;
