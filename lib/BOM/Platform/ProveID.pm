package BOM::Platform::ProveID;

use Moo;

use 5.010;
use strict;
use warnings;

use BOM::Config::Runtime;
use BOM::Config;
use BOM::Platform::S3Client;
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
use Future;

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

The XML result received from the Experian request. 

=cut

has xml_result => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_xml_result',
);

=head2 folder

Path to where the XML and pdf results will be stored

=cut

has folder => (
    is => 'lazy',
);

=head2 xml_folder

Path to where the XML result will be stored. Defaults to C<folder . "/xml"`.

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

=head2 _file_name

The base names of the saved XML and pdf file. Defaults to C<$loginid . "." . $search_option>

=cut

has _file_name => (
    is => 'lazy',
);

=head2 _xml_file_name

The name of the saved XML file.

=cut

has _xml_file_name => (
    is => 'lazy',
);

=head2 _pdf_file_name

The name of the saved pdf file

=cut

has _pdf_file_name => (
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

URL of experian's website for PDF downloading.

=cut

has experian_url => (
    is      => 'ro',
    default => BOM::Config::third_party()->{proveid}->{experian_url});

=head2 xml_parser

Instance of L<XML::LibXML>. Used for parsing the XML result from Experian.

=cut

has xml_parser => (
    is      => 'ro',
    default => sub { return XML::LibXML->new; });

=head2 s3client

Instance of L<BOM::Platform::S3Client>. Used for storing XML and pdf files.

=cut

has s3client => (
    is      => 'ro',
    default => sub {
        my $config = BOM::Config::backoffice()->{experian_document_s3} // {
            aws_bucket            => 'test_bucket',
            aws_region            => 'test_region',
            aws_access_key_id     => 'test_id',
            aws_secret_access_key => 'test_access_key',
        };
        return BOM::Platform::S3Client->new($config);
    });

=head2 xml_url

URL of XML file on S3 server

=cut

has xml_url => (
    is => 'lazy',
);

=head2 pdf_url

URL of pdf file on S3 server

=cut

has pdf_url => (
    is => 'lazy',
);

=head1 METHODS

=cut

=head2 new(client => $client, key => value)

Contructor. Client key/value pair is required, other key/value pairs are optional. 

  my $obj = Experian->new(client => $client);
  my $obj = Experian->new(client => $client, username => $username, password => $password);

=cut

=head2 get_result

  my $xml_result = $experian_obj->get_result();
  

Full wrapping function that makes the XML request, saves the XML result, saves the pdf result and returns the XML result.

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

=head2 upload_xml

  my $future = $self->upload_xml;

Upload XML file onto S3. Return a Future object

=cut

sub upload_xml {
    my ($self) = @_;
    die "requested XML result for uploading is not available" unless $self->xml_result;
    my $tmp_file = Path::Tiny::tempfile;
    $tmp_file->spew($self->xml_result);
    return $self->_upload_file(xml => $tmp_file);
}

=head2 upload_pdf

  my $future = $self->upload_pdf($pdffile);

Generate pdf file (Path::Tiny object) from XML and upload pdf file onto S3. Return a Future object

=cut

sub upload_pdf {
    my ($self, $pdf_file) = @_;
    return $self->_upload_file(pdf => $pdf_file);
}

=head2 get_xml_result

  my $xml_result = $experian_obj->get_xml_result();

Makes the Experian request and returns the XML result from Experian.

=cut

sub get_xml_result {
    my $self = shift;

    my $request = $self->_build_xml_request;

    # This is required to pass in the two factor authentication token through the header of the SOAP request as was stated in an email from Experian :
    #   And the following namespace is needed to pass the signature :
    #   xmlns:head=http://xml.proveid.experian.com/xsd/Headers
    my $header_namespace = 'http://xml.proveid.experian.com/xsd/Headers';
    my $soap = SOAP::Lite->readable(1)->uri($self->api_uri)->proxy($self->api_proxy)->ns($header_namespace, 'head');

    my $som;
    try {
        $som = $soap->search(SOAP::Data->type('xml' => $request), $self->_2fa_header);
    }
    catch {
        die "Connection error\n";    ## Do not echo $_ here, as it can contain a path
    };

    die "Encountered SOAP Fault when sending XML request : " . $som->faultcode . " : " . $som->faultstring if $som->fault;

    my $result = $som->result;
    $self->xml_result($result);

    return 1;
}

=head2 _upload_file

upload files onto S3.

$type: xml or pdf
$file: Path::Tiny object

=cut

sub _upload_file {
    my ($self, $type, $file) = @_;
    die "Type should be xml or pdf" unless $type && $type =~ /xml|pdf/;
    die "File has to be a Path::Tiny object" unless $file && $file->isa('Path::Tiny');
    my $file_name = $type eq 'xml' ? $self->_xml_file_name : $self->_pdf_file_name;
    my $old_file  = $type eq 'xml' ? $self->_has_old_xml   : $self->_has_old_pdf;
    my $checksum  = Digest::MD5->new->addfile($file->filehandle('<'))->hexdigest;
    return $self->s3client->upload($file_name, "$file", $checksum)->then(
        sub {
            $old_file->remove if $old_file;
            return Future->done(@_);
        });
}

=head2 _save_xml_result

Called as part of C<get_result>. Saves the XML result into C<xml_folder>. 

=cut

sub _save_xml_result {
    my $self = shift;

    die "No XML request to save" unless $self->xml_result;

    my $xml = $self->xml_parser->parse_string($self->xml_result);

    if (my ($error_code_node) = $xml->findnodes('/Search/ErrorCode')) {
        my ($error_message_node) = $xml->findnodes('/Search/ErrorMessage');

        die "Experian XML Request Failed with ErrorCode: "
            . $error_code_node->textContent()
            . ", ErrorMessage: "
            . $error_message_node->textContent();
    }

    $self->upload_xml->get;
    return 1;
}

=head2  get_pdf_result

Called as part of C<get_result>

Logins to C<experian_url> with C<username>, C<password> and the SSL key/cert for two factor authentication. Uses the C<OurReference> tag from the XML result to get the corresponding PDF. Then saves the PDF result into C<folder_pdf>

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

    my $dl_tx = $ua->get("$url/archive/index.cfm?event=archive.pdf&id=$our_ref");

    unless ($dl_tx->success) {
        my $err = $login_tx->error;
        die "$err->{code} response: $err->{message}" if $err->{code};
        die "Connection error: $err->{message}";
    }

    my $pdf_file = Path::Tiny::tempfile;
    $dl_tx->res->content->asset->move_to($pdf_file);
    $self->upload_pdf($pdf_file)->get;
    return 1;
}

=head2

The request structure is built based on Section 6 of L<Experian's API|https://github.com/regentmarkets/third_party_API_docs/blob/master/AML/20160520%20Experian%20ID%20Search%20XML%20API%20v1.22.pdf>

The following methods are all part of the building of the XML

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

    my $xml_report_filepath = $self->xml_folder . "/" . $self->_file_name;
    my $pdf_report_filepath = $self->pdf_folder . "/" . $self->_pdf_file_name;

    Path::Tiny::path($xml_report_filepath)->remove();
    Path::Tiny::path($pdf_report_filepath)->remove();

    Future->wait_all(map { $self->s3client->delete($_) } ($self->_xml_file_name, $self->_pdf_file_name))->else_done(0)->get;

    return 1;
}

=head2 _has_old_xml

Returns path object if there is a saved XML at $xml_folder . "/" . $file_name , else undef

=cut

sub _has_old_xml {
    my $self    = shift;
    my $old_xml = path($self->xml_folder . "/" . $self->_file_name);
    return $old_xml->exists ? $old_xml : undef;
}

=head2 _has_old_pdf

Returns path object if there is a saved PDF at $pdf_folder . "/" . $file_name, else undef

=cut

sub _has_old_pdf {
    my $self    = shift;
    my $old_pdf = path($self->pdf_folder . "/" . $self->_file_name);
    return $old_pdf->exists ? $old_pdf : undef;
}

=head2 has_saved_xml

Returns 1 if there is a saved XML at local dir or S3 server

=cut

sub has_saved_xml {
    my $self = shift;
    return $self->_has_old_xml
        || $self->s3client->head_object($self->_xml_file_name)->then_done(1)->else_done(0)->get;
}

=head2 has_saved_pdf

Returns 1 if there is a saved pdf at local dir or S3 server.

=cut

sub has_saved_pdf {
    my $self = shift;
    return $self->_has_old_pdf
        || $self->s3client->head_object($self->_pdf_file_name)->then_done(1)->else_done(0)->get;
}

=head2 BUILDERS

These are the list of builders for some of the attributes of this module

=over

=item _build_folder
=item _build_xml_folder
=item _build_pdf_folder
=item _build__file_name
=item _build__xml_file_name
=item _build__pdf_file_name
=item _build_xml_url
=item _build_pdf_url

=back

=cut

sub _build_xml_result {
    my $self = shift;
    return '' unless $self->has_saved_xml;

    my $s3_error;
    my ($result) = $self->s3client->download($self->_xml_file_name)->else(sub { $s3_error = shift; Future->done('') })->get;

    # for back compatible
    $result ||= try { path($self->xml_folder . "/" . $self->_file_name)->slurp_utf8 } catch { return '' };

    warn "There is no such experian document on either local dir or S3. Maybe S3 has problem: $s3_error" unless $result;
    return $result;
}

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

sub _build__file_name {
    my $self = shift;
    return $self->client->loginid . "." . $self->search_option;
}

sub _build__xml_file_name {
    my $self = shift;
    return $self->_file_name . '.xml';
}

sub _build__pdf_file_name {
    my $self = shift;
    return $self->_file_name . '.pdf';
}

sub _build_xml_url {
    my $self = shift;
    return undef if $self->_has_old_xml;
    return $self->s3client->get_s3_url($self->_xml_file_name);
}

sub _build_pdf_url {
    my $self = shift;
    return undef if $self->_has_old_xml;
    return $self->s3client->get_s3_url($self->_pdf_file_name);
}

1;

