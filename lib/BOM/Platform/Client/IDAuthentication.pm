package BOM::Platform::Client::IDAuthentication;

use Moo;
use Try::Tiny;
use List::Util qw( first );

use Brands;
use BOM::User::Client;
use BOM::Config;
use XML::LibXML;
use Text::Markdown;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(localize request);
use BOM::Platform::ProveID;

has client => (
    is       => 'ro',
    required => 1
);

use constant NEEDED_MATCHES_FOR_UKGC_AUTH        => 2;
use constant NEEDED_MATCHES_FOR_AGE_VERIFICATION => 1;

=head2 run_validation

Takes in a client event name and runs the appropriate validations for that event

=cut

sub run_validation {
    my ($self, $event) = @_;

    my $client  = $self->client;
    my $loginid = $client->loginid;

    return if $client->is_virtual || $client->fully_authenticated;

    my $landing_company = $client->landing_company;

    my $actions = $landing_company->actions->{$event};

    my %error_info = ();

    my $action_mapping = {
        age_verified     => '_age_verified',
        fully_auth_check => '_fully_auth_check',
        proveid          => 'proveid',
    };

    for my $action (@$actions) {
        my $mapped_action = $action_mapping->{$action};
        unless ($mapped_action) {
            warn "Invalid requirement";
            next;
        }

        try {
            $self->$mapped_action();
        }
        catch {
            $error_info{$action} = $_;
        };
    }

    warn "$loginid $event validation $_ fail: " . $error_info{$_} for keys %error_info;

    return 1;
}

=head2 run_authentication

This is called for validation checks on first time deposits. Deprecated for run_validation().

=cut

sub run_authentication {
    return shift->run_validation('first_deposit');
}

=head2 proveid

Checks the proveid results of the client from Experian

=over 4

=item * C<should_die> - Boolean, if set, the proveid will die on failure

=cut

sub proveid {
    my $self    = shift;
    my $client  = $self->client;
    my $loginid = $client->loginid;

    return undef unless $client->residence eq 'gb';

    my $prove_id_result = $self->_fetch_proveid;

    return undef unless $prove_id_result;

    my $xml = XML::LibXML->new()->parse_string($prove_id_result);

    my ($credit_reference)         = $xml->findnodes('/Search/Result/CreditReference');
    my ($credit_reference_summary) = $xml->findnodes('/Search/Result/CreditReference/CreditReferenceSummary');
    my ($kyc_summary)              = $xml->findnodes('/Search/Result/Summary/KYCSummary');
    my ($report_summary)           = $xml->findnodes('/Search/Result/Summary/ReportSummary/DatablocksSummary');

    if (($credit_reference->getAttribute('Type') =~ /NoMatch|Error/) || (!$kyc_summary->hasChildNodes)) {
        $self->_process_not_found;
        return undef;
    }

    my $matches = {};

    my @tags_to_match = ("Deceased", "PEP", "BOE", "OFAC");

    for my $tag (@tags_to_match) {
        try {
            $matches->{$tag} = $credit_reference_summary->findnodes($tag . "Match")->[0]->textContent() || 0;
        }
        catch {
            $matches->{$tag} = 0;
            warn $_;
        };
    }

    my @invalid_matches = grep { $matches->{$_} > 0 } keys %$matches;

    if (@invalid_matches) {
        my $msg = join(", ", @invalid_matches);
        $client->status->set('disabled', 'system', "Experian categorizes this client as $msg.");
        $self->_notify_cs("Account $loginid disabled following Experian results",
            "Experian results has marked this client as $msg and an email has been sent out to the client requesting for Proof of Identification.");
        return $self->_request_id_authentication();
    }

    # Handle DOB match for age verification
    my $dob_match = ($kyc_summary->findnodes("DateOfBirth/Count"))[0]->textContent();
    # Handle Firstname and Address match for UKGC verification
    my $name_address_match = ($kyc_summary->findnodes("FullNameAndAddress/Count"))[0]->textContent();

    if ($dob_match >= NEEDED_MATCHES_FOR_AGE_VERIFICATION) {
        $client->status->set('age_verification', 'system', "Experian results are sufficient to mark client as age verified.");
        my $vr_acc = BOM::User::Client->new({loginid => $client->user->bom_virtual_loginid});
        $vr_acc->status->clear_unwelcome;
        $vr_acc->status->set('age_verification', 'system', 'Experian results are sufficient to mark client as age verified.');
        if ($name_address_match >= NEEDED_MATCHES_FOR_UKGC_AUTH) {
            $client->status->set('ukgc_authenticated', 'system', "Online verification passed");
        } else {
            $client->status->set('unwelcome', 'system', "Experian results are insufficient to enable deposits.");

            $self->_request_id_authentication();
        }
    } else {
        $client->status->set('unwelcome', 'system', "Experian results are insufficient to mark client as age verified.");

        $self->_request_id_authentication();
    }

    return undef;
}

=head2 _age_verified

Checks if client is age verified, if not, set cashier lock on client

=cut

sub _age_verified {
    my $self    = shift;
    my $client  = $self->client;
    my $loginid = $client->loginid;

    if (!$client->status->age_verification && !$client->has_valid_documents) {
        $client->status->set('cashier_locked', 'system', 'Age verification is needed after first deposit.');
        $self->_request_id_authentication();
    }

    return undef;
}

=head2 _fully_auth_check

Checks if client is fully authenticated, if not, set client as unwelcome

=cut

sub _fully_auth_check {
    my $self   = shift;
    my $client = $self->client;

    $client->status->set("unwelcome", "system", "Client was not fully authenticated before making first deposit") unless $client->fully_authenticated;

    return undef;
}

=head2 _fetch_proveid

Fetches the proveid result of the client from Experian through BOM::Platform::ProveID

=cut

sub _fetch_proveid {
    my $self    = shift;
    my $client  = $self->client;
    my $loginid = $client->loginid;

    my $result;
    try {
        $client->status->set('proveid_requested', 'system', 'ProveID request has been made for this account.');

        $result = BOM::Platform::ProveID->new(client => $self->client)->get_result;
    }
    catch {
        my $error = $_;

        # ErrorCode 500 and 501 are Search Errors according to Appendix B of https://github.com/regentmarkets/third_party_API_docs/blob/master/AML/20160520%20Experian%20ID%20Search%20XML%20API%20v1.22.pdf
        if ($error =~ /50[01]/) {
            $self->_process_not_found;
            return undef;    # Do not die, if the client was not found
        }

        # We set this flag for when the ProveID request fails and "cron_download_missing_192_pdf_reports.pl" will retry ProveID requests for these accounts every 1 hours
        $client->status->set('proveid_pending', 'system', 'Experian request failed and will be attempted again within 1 hour.');
        $client->status->set('unwelcome',       'system', 'FailedExperian - Experian request failed and will be attempted again within 1 hour.');

        my $brand   = Brands->new(name => request()->brand);
        my $loginid = $self->client->loginid;
        my $message = <<EOM;
There was an error during Experian request.
Error is: $error
Client: $loginid
EOM
        send_email({
                from    => $brand->emails('compliance'),
                to      => $brand->emails('compliance'),
                subject => "Experian request error for client $loginid",
                message => [$message]});

        die 'Failed to contact the ProveID server';
    };

    # On successful requests, we clear this status so the cron job will not retry ProveID requests on this account
    $client->status->clear_proveid_pending;

    # Clear unwelcome status set from failing Experian request
    my $unwelcome_status = $client->status->unwelcome;
    $client->status->clear_unwelcome if ($unwelcome_status && $unwelcome_status->{reason} =~ /^FailedExperian/);

    return $result;
}

=head2 _request_id_authentication

Sends an email to the client requesting for Proof of Identity

=cut

sub _request_id_authentication {
    my $self   = shift;
    my $client = $self->client;

    my $client_name = join(' ', $client->salutation, $client->first_name, $client->last_name);
    my $brand         = Brands->new(name => request()->brand);
    my $support_email = $brand->emails('support');
    my $subject       = localize('Documents are required to verify your identity');

    # Since this is an HTML email, plain text content will be mangled badly. Instead, we use
    # Markdown syntax, since there are various converters and the plain text to HTML options
    # in Perl are somewhat limited and/or opinionated.
    my $body = localize(<<'EOM', $client_name, $brand->website_name, $support_email);
Dear [_1],

Thank you for creating your [_2] account!

As the next step, we’ll need to authenticate your account with proof of your identity and address. To help us with this, please forward scanned copies of the following to [_3]:

- Valid passport, driving licence, or national ID card
- Bank statement or utility bill (phone bills are not accepted)

After authentication is complete, your account will be enabled for trading, deposits, and withdrawals.

Thank you for choosing [_2]!

Sincerely,
Team [_2]

EOM

    return send_email({
            from    => $support_email,
            to      => $client->email,
            subject => $subject,
            message => [
                Text::Markdown::markdown(
                    $body,
                    {
                        # Defaults to the obsolete XHTML format
                        empty_element_suffix => '>',
                        tab_width            => 4,
                    })
            ],
            use_email_template    => 1,
            email_content_is_html => 1,
            skip_text2html        => 1,
            template_loginid      => $client->loginid,
        });
}

=head _notify_cs($subject, $body)

Adds an entry in desk.com for the client with $subject and $body

=cut

sub _notify_cs {
    my ($self, $subject, $body) = @_;

    return unless BOM::Config::on_production();    #TODO Remove when desk.com mocked server is ready. Also merge to main sub

    my $client = $self->client;
    $client->add_note($subject, $client->loginid . ' ' . $body);

    return undef;
}

=head _process_not_found

Handles client which has no entry found in Experian's database

=cut

sub _process_not_found {
    my $self   = shift;
    my $client = $self->client;

    $client->status->set('unwelcome', 'system', 'No entry for this client found in Experian database.');
    $client->status->clear_proveid_pending;
    $self->_request_id_authentication();

    return undef;
}

1;
