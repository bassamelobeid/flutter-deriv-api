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

=head2 run_authentication

This is called for validation checks on first time deposits

=cut

sub run_authentication {
    my $self    = shift;
    my $client  = $self->client;
    my $loginid = $client->loginid;

    return if $client->is_virtual || $client->fully_authenticated;

    my $landing_company = $client->landing_company;

    $client->send_new_client_email() if ($landing_company->new_client_email_event eq 'first_deposit');

    my $requirements = $landing_company->first_deposit_requirements;

    my $action_mapping = {
        age_verified => \&_age_verified,
        proveid      => \&_proveid,
        fully_auth   => \&_fully_auth,
    };

    for my $req (@$requirements) {
        unless (exists $action_mapping->{$req}) {
            warn "Invalid requirement";
            next;
        }
        $action_mapping->{$req}->($self);
    }

    return;
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

=head2 _fully_auth

Checks if client is fully authenticated, if not, set client as unwelcome

=cut

sub _fully_auth {
    my $self   = shift;
    my $client = $self->client;

    $client->status->set("unwelcome", "system", "Client was not fully authenticated before making first deposit") unless $client->fully_authenticated;

    return undef;
}

=head2 _proveid

Checks the proveid results of the client from Experian

=cut

sub _proveid {
    my $self    = shift;
    my $client  = $self->client;
    my $loginid = $client->loginid;

    return undef unless $client->residence eq 'gb';

    my $prove_id_result = $self->_fetch_proveid;

    return undef unless $prove_id_result;
    my $xml = XML::LibXML->new()->parse_string($prove_id_result);

    my ($credit_reference_summary) = $xml->findnodes('/Search/Result/CreditReference/CreditReferenceSummary');
    my ($kyc_summary)              = $xml->findnodes('/Search/Result/Summary/KYCSummary');
    my ($report_summary)           = $xml->findnodes('/Search/Result/Summary/ReportSummary/DatablocksSummary');

    my $matches = {};

    $matches->{"Deceased"} = $credit_reference_summary->findnodes('DeceasedMatch')->[0]->textContent() || 0;
    $matches->{"Fraud"} =
        $report_summary->findnodes('//DatablockSummary[Name="Fraud"]/Decision')->[0]->textContent() || 0;
    $matches->{"PEP"}  = $credit_reference_summary->findnodes('PEPMatch')->[0]->textContent()  || 0;
    $matches->{"BOE"}  = $credit_reference_summary->findnodes('BOEMatch')->[0]->textContent()  || 0;
    $matches->{"OFAC"} = $credit_reference_summary->findnodes('OFACMatch')->[0]->textContent() || 0;

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
        my $status_set_response =
            $client->status->set('age_verification', 'system', "Experian results are sufficient to mark client as age verified.");
        if ($name_address_match >= NEEDED_MATCHES_FOR_UKGC_AUTH) {
            $status_set_response = $client->status->set('ukgc_authenticated', 'system', "Online verification passed");
        }
        return $status_set_response;
    } else {
        $client->status->set('unwelcome', 'system', "Experian results are insufficient to mark client as age verified.");
        $self->_notify_cs(
            "Account $loginid unwelcome following Experian results",
            "Experian results was insufficient to mark client as age verified and an email has been sent out to the client requesting for Proof of Identification."
        );
        return $self->_request_id_authentication();
    }
}

=head2 _fetch_proveid

Fetches the proveid result of the client from Experian through BOM::Platform::ProveID

=cut

sub _fetch_proveid {
    my $self    = shift;
    my $client  = $self->client;
    my $loginid = $client->loginid;

    my $result;
    my $successful_request;
    try {
        $client->status->set('proveid_requested', 'system', 'ProveID request has been made for this account.');

        $result = BOM::Platform::ProveID->new(client => $self->client)->get_result;

        $successful_request = 1;
    }
    catch {
        my $error = $_;

        if ($error =~ /^50[01]/
            ) # ErrorCode 500 and 501 are Search Errors according to Appendix B of https://github.com/regentmarkets/third_party_API_docs/blob/master/AML/20160520%20Experian%20ID%20Search%20XML%20API%20v1.22.pdf
        {
            # We don't retry when there is a search error (no entry or otherwise)
            $client->status->set('unwelcome', 'system', 'No entry for this client found in Experian database.');
            $self->_notify_cs(
                "Account $loginid unwelcome due to lack of entry in Experian database",
                "An email has been sent out to the client requesting for Proof of Identification."
            );
            $self->_request_id_authentication();
            $successful_request = 1;    # Successful request made, even if response is invalid
        } else {
            # We set this flag for when the ProveID request fails and "cron_download_missing_192_pdf_reports.pl" will retry ProveID requests for these accounts every 12 hours
            $client->status->set('proveid_pending', 'system', 'Experian request failed and will be attempted again within 12 hours.');
            $client->status->set('unwelcome', 'system', 'FailedExperian - Experian request failed and will be attempted again within 12 hours.');

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
            $successful_request = 0;
        }
    };

    if ($successful_request) {
        # On successful requests, we clear this status so the cron job will not retry ProveID requests on this account
        $client->status->clear_proveid_pending;

        # Clear unwelcome status set from failing Experian request
        my $unwelcome_status = $client->status->unwelcome;
        $client->status->clear_unwelcome if ($unwelcome_status && $unwelcome_status->{reason} =~ /^FailedExperian/);
    }

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

We are writing to you regarding your account with [_2].

We are legally required to verify that clients are over the age of 18, and so we request that you forward scanned copies of one of the following to [_3]:

- Valid Passport or Driving licence or National ID card

In order to comply with licencing regulations, you will be unable to make further deposits or withdrawals or to trade with your account until we receive this document.

We look forward to hearing from you soon.

Kind regards,

[_2]
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

1;
