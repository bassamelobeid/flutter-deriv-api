package BOM::Platform::ProveID;

use Moo;

use 5.010;
use strict;
use warnings;

use BOM::Config::Runtime;
use BOM::Config;
use Locale::Country;
use Path::Tiny;
use Try::Tiny;
use Mojo::UserAgent;
use Mojo::UserAgent::CookieJar;
use XML::Simple;
use XML::Twig;
use SOAP::Lite;
use IO::Socket::SSL 'SSL_VERIFY_NONE';
use Digest::SHA qw/hmac_sha256_base64/;
use List::Util qw /first/;

our $VERSION = '0.001';

=head1 NAME

perl::Experian - Module abstract

=head1 SYNOPSIS

    use BOM::Platform::ProveID;
    my $xml_result = BOM::Platform::ProveID->new(client => $client)->get_result();
    my $xml_result = BOM::Platform::ProveID->new(client => $client, api_uri => $custom_uri, api_proxy => $custom_proxy)->get_result();
    my $xml_result = BOM::Platform::ProveID->new(client => $client, username => $username, password => $password)->get_result();

=head1 DESCRIPTION

An interface to Experian's ID Authentication Service. Handles connecting to experian, constructing the suitable request and saving the results where appropriate.

=cut

=head1 ATTRIBUTES

=cut

=head2 client

The client object used to populate the details for the request to Experian
    
=cut

has client => (
    is       => 'ro',
    required => 1
);

=head2 search_option

Search option used in the Experian request. The list of options are available at Section 6.1 of L<Experian's API|https://github.com/regentmarkets/third_party_API_docs/blob/master/AML/20160520%20Experian%20ID%20Search%20XML%20API%20v1.22.pdf>

=cut

has search_option => (
    is      => 'ro',
    default => 'ProveID_KYC'
);

=head2 xml_result

The xml result received from the Experian request. 

=cut

has xml_result => (
    is      => 'rw',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $res = try { Path::Tiny::path($self->xml_folder . "/" . $self->file_name)->slurp } catch { return '' };

        return $res;
    });

=head2 folder

Path to where the xml and pdf results will be stored

=cut

has folder => (
    is => 'lazy',
);

=head2 xml_folder

Path to where the xml result will be stored. Defaults to C<folder . "/xml"`.

=cut

has xml_folder => (
    is => 'lazy',
);

=head2 pdf_folder

Path to where the pdf result will be stored. Defaults to C<folder . "/pdf">.

=cut

has pdf_folder => (
    is => 'lazy',
);

=head2 file_name

The names of the saved xml and pdf file names. Defaults to C<$loginid . "." . $search_option>

=cut

has file_name => (
    is => 'lazy',
);

=head2 username

Username used for both authentication for Experian's API and logging into C<experian_url> for pdf downloading.

=cut

has username => (
    is      => 'ro',
    default => BOM::Config::third_party()->{proveid}->{username});

=head2 password

Password used for both authentication for Experian's API and logging into C<experian_url> for PDF downloading.

=cut

has password => (
    is      => 'ro',
    default => BOM::Config::third_party()->{proveid}->{password});

has pdf_username => (
    is      => 'ro',
    default => BOM::Config::third_party()->{proveid}->{pdf_username});

has pdf_password => (
    is      => 'ro',
    default => BOM::Config::third_party()->{proveid}->{pdf_password});

=head2 private_key

Private key used in the Experian API two factor authentication.

=cut

has private_key => (
    is      => 'ro',
    default => BOM::Config::third_party()->{proveid}->{private_key});

=head2 private_key

Public key used in the Experian API two factor authentication.

=cut

has public_key => (
    is      => 'ro',
    default => BOM::Config::third_party()->{proveid}->{public_key});

=head2 api_uri

Experian's namespace URI used for constructing the SOAP request

=cut

has api_uri => (
    is      => 'ro',
    default => BOM::Config::third_party()->{proveid}->{api_uri});

=head2 api_proxy

Experian's proxy endpoint configuration for constructing the SOAP request

=cut

has api_proxy => (
    is      => 'ro',
    default => BOM::Config::third_party()->{proveid}->{api_proxy}

);

=head2 experian_url

Url of experian's website for PDF downloading.

=cut

has experian_url => (
    is      => 'ro',
    default => BOM::Config::third_party()->{proveid}->{experian_url});

=head2 xml_parser

Instance of L<XML::LibXML>. Used for parsing the xml result from Experian.

=cut

has xml_parser => (
    is      => 'ro',
    default => sub { return XML::LibXML->new; });

=head1 METHODS

=cut

=head2 new(client => $client, key => value)

Contructor. Client key/value pair is required, other key/value pairs are optional. 

  my $obj = Experian->new(client => $client);
  my $obj = Experian->new(client => $client, username => $username, password => $password);

=cut

=head2 get_result

  my $xml_result = $experian_obj->get_result();
  
Full wrapping function that makes the xml request, saves the xml result, saves the pdf result and returns the xml result.

=cut

sub get_result {
    my $self = shift;

    $self->get_xml_result;

    $self->_save_xml_result;
    try {
        $self->get_pdf_result;
    }
    catch {
        warn "$_";
    };

    return $self->xml_result;
}

=head2 get_xml_result

  my $xml_result = $experian_obj->get_xml_result();

Makes the Experian request and returns the xml result from Experian.

=cut

sub get_xml_result {
    my $self = shift;

    my $request = $self->_build_xml_request;

    # This is required to pass in the two factor authentication token through the header of the SOAP request as was stated in an email from Experian :
    #   And the following namespace is needed to pass the signature :
    #   xmlns:head=http://xml.proveid.experian.com/xsd/Headers
    my $header_namespace = 'http://xml.proveid.experian.com/xsd/Headers';
    my $soap = SOAP::Lite->readable(1)->uri($self->api_uri)->proxy($self->api_proxy)->ns($header_namespace, 'head');

    my $som = $soap->search(SOAP::Data->type('xml' => $request), $self->_2fa_header);

    die "Encountered SOAP Fault when sending xml request : " . $som->faultcode . " : " . $som->faultstring if $som->fault;

    my $result = $som->result;
    $self->xml_result($result);

    return 1;
}

=head2 _save_xml_result

Called as part of C<get_result>. Saves the xml result into C<xml_folder>. 

=cut

sub _save_xml_result {
    my $self = shift;

    die "No xml request to save" unless $self->xml_result;

    my $xml = $self->xml_parser->parse_string($self->xml_result);

    if (my ($error_code_node) = $xml->findnodes('/Search/ErrorCode')) {
        my ($error_message_node) = $xml->findnodes('/Search/ErrorMessage');

        die "Experian XML Request Failed with ErrorCode: "
            . $error_code_node->textContent()
            . ", ErrorMessage: "
            . $error_message_node->textContent();
    }

    my $xml_report_filepath = $self->xml_folder . "/" . $self->file_name;

    # Create directory if it doesn't exist
    Path::Tiny::path($self->xml_folder)->mkpath unless -d -x $self->xml_folder;

    # Path::Tiny spew overwrites any existing data
    Path::Tiny::path($xml_report_filepath)->spew($self->xml_result);

    return 1;
}

=head2  get_pdf_result

Called as part of C<get_result>

Logins to C<experian_url> with C<username>, C<password> and the SSL key/cert for two factor authentication. Uses the C<OurReference> tag from the xml result to get the corresponding PDF. Then saves the PDF result into C<folder_pdf>

=cut

sub get_pdf_result {
    my $self = shift;

    my $xml = $self->xml_parser->parse_string($self->xml_result);

    my ($our_ref_node) = $xml->findnodes('/Search/OurReference');

    die "XML result has no OurReference needed for PDF request" unless $our_ref_node;

    my $our_ref = $our_ref_node->textContent();

    my $url = $self->experian_url;

    my $ua = Mojo::UserAgent->new->cookie_jar(Mojo::UserAgent::CookieJar->new);

    $ua->key('/etc/rmg/ssl/key/experian.key');
    $ua->cert('/etc/rmg/ssl/crt/experian.crt');

    my $login_tx = $ua->post(
        "$url/signin/onsignin.cfm" => form => {
            _CSRF_token => $ua->get("$url/signin/")->result->dom->at('input[name=_CSRF_token]')->attr('value'),
            login       => $self->pdf_username,
            password    => $self->pdf_password,
            btnSubmit   => 'Login'
        });

    unless ($login_tx->success) {
        my $err = $login_tx->error;
        die "$err->{code} response: $err->{message}" if $err->{code};
        die "Connection error: $err->{message}";
    }

    my $pdf_report_filepath = $self->pdf_folder . "/" . $self->file_name . ".pdf";

    # Create directory if it doesn't exist
    Path::Tiny::path($self->pdf_folder)->mkpath unless -d -x $self->pdf_folder;

    my $dl_tx = $ua->get("$url/archive/index.cfm?event=archive.pdf&id=$our_ref");

    unless ($dl_tx->success) {
        my $err = $login_tx->error;
        die "$err->{code} response: $err->{message}" if $err->{code};
        die "Connection error: $err->{message}";
    }

    # move_to overwrites any existing data
    $dl_tx->res->content->asset->move_to($pdf_report_filepath);
    return 1;
}

=head2
    
The request structure is built based on Section 6 of L<Experian's API|https://github.com/regentmarkets/third_party_API_docs/blob/master/AML/20160520%20Experian%20ID%20Search%20XML%20API%20v1.22.pdf>

The following methods are all part of the building of the xml

=over

=item _build_authentication_tag
=item _build_country_code_tag
=item _build_person_tag
=item _build_addresses_tag
=item _build_telephones_tag
=item _build_search_reference_tag
=item _build_search_option_tag

=back

Note that the search reference tag is not required in the request but is included for our auditing purposes

=cut

sub _build_xml_request {
    my $self = shift;

    return (  '<xml><![CDATA[<Search>'
            . $self->_build_authentication_tag
            . $self->_build_country_code_tag
            . $self->_build_person_tag
            . $self->_build_addresses_tag
            . $self->_build_telephones_tag
            . $self->_build_search_reference_tag
            . $self->_build_search_option_tag
            . '</Search>]]></xml>');
}

sub _build_authentication_tag {
    my $self = shift;

    return "<Authentication><Username>" . $self->username . "</Username><Password>" . $self->password . "</Password></Authentication>";
}

sub _build_person_tag {
    my $self = shift;

    return
          '<Person>'
        . '<Name><Forename>'
        . $self->client->first_name
        . '</Forename>'
        . '<Surname>'
        . $self->client->last_name
        . '</Surname></Name>'
        . '<DateOfBirth>'
        . $self->client->date_of_birth
        . '</DateOfBirth>'
        . '</Person>';
}

sub _build_addresses_tag {
    my $self = shift;

    my $premise      = $self->client->address_1;
    my $postcode     = $self->client->postcode // '';
    my $country_code = $self->_build_country_code_tag;

    return
          '<Addresses><Address Current="1"><Premise>'
        . $premise
        . ' </Premise><Postcode>'
        . $postcode
        . '</Postcode>'
        . $country_code
        . '</Address></Addresses>';
}

sub _build_country_code_tag {
    my $self = shift;

    my $two_letter_country_code = $self->client->residence;
    my $three_letter_country_code = uc(Locale::Country::country_code2code($two_letter_country_code, LOCALE_CODE_ALPHA_2, LOCALE_CODE_ALPHA_3) // "");

    die "Client " . $self->client->loginid . " could not get three letter country code from residence $two_letter_country_code"
        unless $three_letter_country_code;

    return "<CountryCode>" . $three_letter_country_code . "</CountryCode>";
}

sub _build_telephones_tag {
    my $self = shift;

    my $telephone_type = 'U'
        ; # U is for unkown. This is left here so we can easily implement different specific telephone type queries in the future. Reference for this can be found in Section 11.3 of Experian's API

    return '<Telephones><Telephone Type="' . $telephone_type . '"><Number>' . $self->client->phone . '</Number></Telephone></Telephones>';
}

sub _build_search_reference_tag {
    my $self                    = shift;
    my $search_option_shortcode = 'PK'
        ; # PK is for ProveID_KYC which is currently the only search option we use. This is left here so we can easily implement the use of different search options in the future.
    my $time = time();

    return '<YourReference>' . $search_option_shortcode . '_' . $self->client->loginid . '_' . $time . '</YourReference>';
}

sub _build_search_option_tag {
    my $self = shift;

    return '<SearchOptions><ProductCode>' . $self->search_option . '</ProductCode></SearchOptions>';
}

=head2 _2fa_header

Returns the 2 factor authentication signature based on the L<User Guide we received from Experian|https://github.com/regentmarkets/third_party_API_docs/tree/master/AML> as a L<SOAP::Header> Object

=cut

sub _2fa_header {
    my $self = shift;

    my $loginid     = $self->{username};
    my $password    = $self->{password};
    my $private_key = $self->{private_key};
    my $public_key  = $self->{public_key};

    my $timestamp = time();

    my $hash = hmac_sha256_base64($loginid, $password, $timestamp, $private_key);

    # Digest::SHA doesn't pad it's outputs so we have to do it manually.
    while (length($hash) % 4) {
        $hash .= '=';
    }

    my $hmac_sig = $hash . '_' . $timestamp . '_' . $public_key;

    return SOAP::Header->name('head:Signature')->value($hmac_sig);
}

=head2 delete_existing_reports

Deletes existing reports from Experian if they exist, GDPR requirement

=cut

sub delete_existing_reports {
    my $self   = shift;
    my $client = $self->client;

    my $xml_report_filepath = $self->xml_folder . "/" . $self->file_name;
    my $pdf_report_filepath = $self->pdf_folder . "/" . $self->file_name . ".pdf";

    Path::Tiny::path($xml_report_filepath)->remove();
    Path::Tiny::path($pdf_report_filepath)->remove();

    return 1;
}

=head2 has_saved_xml

Returns 1 if there is a saved xml at $xml_folder . "/" . $file_name

=cut

sub has_saved_xml {
    my $self = shift;
    return -e $self->xml_folder . "/" . $self->file_name;
}

=head2 has_saved_pdf

Returns 1 if there is a saved pdf at $pdf_folder . "/" . $file_name . ".pdf";

=cut

sub has_saved_pdf {
    my $self = shift;
    return -e $self->pdf_folder . "/" . $self->file_name . ".pdf";
}

=head2 BUILDERS

These are the list of builders for some of the attributes of this module

=over

=item _build_folder
=item _build_xml_folder
=item _build_pdf_folder
=item _build_file_name

=back

=cut

sub _build_folder {
    my $self = shift;

    my $broker = $self->client->broker;
    return "/db/f_accounts/$broker/192com_authentication";
}

sub _build_xml_folder {
    my $self = shift;
    return $self->folder . "/xml";
}

sub _build_pdf_folder {
    my $self = shift;
    return $self->folder . "/pdf";
}

sub _build_file_name {
    my $self = shift;
    return $self->client->loginid . "." . $self->search_option;
}

1;

