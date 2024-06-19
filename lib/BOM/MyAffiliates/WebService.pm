package BOM::MyAffiliates::WebService;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);
use Future::AsyncAwait;
use Log::Any qw($log);
use Net::Async::HTTP;
use Scalar::Util qw(blessed);
use Syntax::Keyword::Try;
use XML::LibXML;
use MIME::Base64 qw(encode_base64);

=head1 NAME

Myaffiliate API wrapper.

=head1 SYNOPSIS

    use BOM::MyAffiliates::WebService;
    my $api = BOM::MyAffiliates::WebService->new(base_url => 'http://go.YOURSITE.com/');
    my $is_usable = $api->register_user('username1', 'password', ....);
    if ($is_usable) {
        print "Registered successfully";
    } else {
        print "Registration Failed!";
    }

=head1 DESCRIPTION

This wrapper is based on MyAffiliate Registration API Document Version 2018-05-29

=cut

use constant BUSINESS_TYPES => {
    Private => 1,
    Company => 1
};

use constant ALLOWED_AFFILIATE_STATUS => {
    pending  => 1,
    approved => 1
};

=head2 new

Instantiate a new Myaffiliate object. It requires the a hash with the following
attributes

=over 4

=item * C<base_uri> - The base URI for the Myaffiliate API.

=back

It returns an instance of MyAffiliateWebService.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = bless {}, $class;
    for (qw(base_uri user pass)) {
        $self->{$_} = $args{$_} || die "$_ is required";
    }

    $self->{auth_base64_value} = encode_base64("$self->{user}:$self->{pass}");

    return $self;
}

=head2 _do_request

Perform a POST request to the Myaffiliate endpoint.

Takes the following parameters

=over 4

=item * C<$api_call> - A STRING describing the API call to perform, currently C<'registeraffiliate'> is supported.

=item * C<$args> - A HASHREF with the arguments required by the endpoint.

=back


It returns a L<Future> that resolves to the response body.

In case of error it will return a HASREF with the following attributes

=over 4

=item * C<error_code> - A numeric code for the error returned, in case of unknown or unexpected errors 10001 will be returned.

=item * C<error_message> - A STRING with the friendly description of the error. 'Unknown error' is returned accordingly.

=item * C<http_code> - The HTTP code returned by the MyAffiliate API. Will return 500 if not http code is received from the API.

=back

=cut

async sub _do_request {
    my ($self, $api_call_number, $args) = @_;
    my $endpoint = URI->new($self->{base_uri} . '/feeds.php?FEED_ID=' . $api_call_number);
    $log->tracef("POST %s with params %s", $endpoint, $args);

    try {
        my $response = await $self->ua->POST(
            $endpoint,
            $args,
            user => $self->{user},
            pass => $self->{pass});

        $log->tracef("Response : %s", $response->content);

        return $response->content;
    } catch ($e) {
        my ($error_code, $error_message, $http_code);

        if (blessed($e) and $e->isa('Future::Exception')) {
            if ($e->category eq 'http') {
                my ($res) = $e->details;
                $http_code     = $res->code;
                $error_message = $res->content;
                # XXX: Try XML request if apply
                ($error_code, $error_message) = split qr/\|/, $res->content if $res->content =~ m/\|/;
            } else {
                $error_message = $e->message if $e->can('message');
            }
        }

        die +{
            error_code    => $error_code    // 10001,
            error_message => $error_message // "$e" // 'Unknown error',
            http_code     => $http_code     // 500,
        };
    }
}

=head2 register_affiliate

Call the Register Affiliate endpoint. It expects a hashref with the following
attributes.

Most of the attributes have 50 characters length at most. If otherwise will be explicitly specified

Takes a HASH as parameter with the following attributes:

=over 4

=item * C<account_type> - type of account we are going to create ( default is shell) Optional.

=item * C<PARAM_username> - The username Required.

=item * C<PARAM_password> - The password (deprecated in MyAffiliate API should remove later on).

=item * C<PARAM_email> - The Email Required.

=item * C<PARAM_country> - The Country name.

=item * C<PARAM_first_name> - The First Name Required.

=item * C<PARAM_last_name> - The Last Name Required.

=item * C<PARAM_date_of_birth> - The date of birth in format of yyyy-mm-dd (i.e: 1990-06-04) Required.

=item * C<PARAM_individual> - Regiration is for Individual=1 or company=2 Required.

=item * C<PARAM_wa_countrycode> - WhatsAppNumber Country Code.

=item * C<PARAM_whatsapp> - Whatsapp Number Required.

=item * C<PARAM_ph_countrycode> - phone number country code.

=item * C<PARAM_phone_number> - phone number Required.

=item * C<PARAM_city> - user city Required.

=item * C<PARAM_state> - user state Required.

=item * C<PARAM_postcode> - user postcode Required.

=item * C<PARAM_website> - user website Required.

=item * C<PARAM_agreement> - user agreement required.

=back

Example:
    my $aff_id = $api->register_affiliate(
        PARAM_email              => 'something1@gmail.com',
        PARAM_username           => 'adalovelace',
        PARAM_first_name         => 'Ada',
        PARAM_last_name          => 'Lovelace',
        PARAM_date_of_birth      => '1990-06-04',
        PARAM_individual         => 1,
        PARAM_whatsapp           => '12341234',
        PARAM_phone_number       => '12341234',
        PARAM_country            => 'AR',
        PARAM_city               => 'City',
        PARAM_state              => 'ST',
        PARAM_postcode           =>  '132423',
        PARAM_website            => 'www.google.com',
        PARAM_agreement          => 1
    )->get;


It returns the a L<Future> with the identifier number for the newly created account. If something fails this sub dies, returning a failed L<Future> with the Error inside.

=cut

async sub register_affiliate {
    my ($self, %args) = @_;
    my $feed_id_number = '26';

    foreach my $key (keys %args) {
        $args{$key} =~ s/^\s+|\s+$//g;
    }

    for (
        qw(PARAM_email PARAM_username PARAM_first_name PARAM_last_name PARAM_date_of_birth PARAM_individual PARAM_phone_number PARAM_city PARAM_state PARAM_website PARAM_agreement)
        )
    {
        die "$_ is required" unless $args{$_};
    }

    my $response = await $self->_do_request($feed_id_number, \%args);

    return $response;
}

=head2 ua

Builds/Returns the User Agent used for the request.

This sub return an instance of L<Net::Async::HTTP>.

=cut

sub ua {
    my $self = shift;
    $self->{ua} = do {
        $self->add_child(
            my $ua = Net::Async::HTTP->new(
                fail_on_error            => 1,
                decode_content           => 1,
                pipeline                 => 0,
                stall_timeout            => 60,
                max_connections_per_host => 2
            ));
        $ua;
    }
}

1;
