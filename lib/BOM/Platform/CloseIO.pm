package BOM::Platform::CloseIO;

use Moo;

use strict;
use warnings;

=head1 NAME

BOM::Platform::CloseIO - CloseIO API wrapper and actions

=head1 SYNOPSIS

    BOM::Platform::CloseIO->new(user => $user_instance);

=head1 DESCRIPTION

An interface to CloseIO service. Handle API communications and some internal actions.

=cut

use HTTP::Tiny;
use JSON::MaybeUTF8 qw( decode_json_utf8 );
use Log::Any qw( $log );
use MIME::Base64 qw( encode_base64 );
use Text::Trim;
use URI;

use BOM::Config;

=head2 user

The user instance

=cut

has user => (
    is       => 'ro',
    required => 1
);

=head2 config

The configuration of B<CloseIO>.

=cut

has config => (
    is      => 'ro',
    default => sub {
        my $config = BOM::Config::third_party()->{close_io} // {};

        $log->error('CloseIO api_url is missed.') unless $config->{api_url} //= '';
        $log->error('CloseIO api_key is missed.') unless $config->{api_key} //= '';

        return $config;
    });

=head2 http

The L<HTTP::Tiny> instance to make HTTP connections

=cut

has http => (
    is      => 'ro',
    default => sub {
        my $self = shift;

        my $token = $self->config->{api_key};

        return HTTP::Tiny->new(
            default_headers => {
                'Authorization' => 'Basic ' . trim(encode_base64("$token:")),
                'Content-Type'  => 'application/json'
            });
    },
);

=head2 anonymize_user

Remove leads related to given user and anonymize it

=cut

sub anonymize_user {
    my ($self) = @_;

    my $search_resp = $self->search_lead($self->user->email);

    return 0
        if ($search_resp and ref $search_resp eq 'HASH' and not $search_resp->{success})
        or not my $search_result = decode_json_utf8 $search_resp;

    return 1 if $search_result->{total_results} == 0;

    my $leads = $search_result->{data};

    for my $lead ($leads->@*) {
        my $del_result = $self->delete_lead($lead->{id});

        unless ($del_result) {
            $log->errorf('An error occurred while anonymizing user %s due to HTTP status: %s, content: %s',
                $self->user->id, $del_result->status, $del_result->content);
            return 0;
        }
    }

    return 1;
}

=head2 search_lead

Search for lead

=over 4

=item C<filters> - An array of keywords to search

=back

Returns,
        json string on successful response;
        hashref on error response;

=cut

sub search_lead {
    my ($self, @filters) = @_;
    die 'Please define at least one filter.' unless @filters and scalar @filters;

    my $params = $self->http->www_form_urlencode({
        query => join ',',
        @filters
    });

    my $response = $self->http->request('GET', $self->config->{api_url} . "lead?$params");

    return $response->{content} if $response->{success};
    return $response;
}

=head2 delete_lead

Delete lead entity

=over 4

=item C<lead_id> - The lead id to remove its data

=back

Returns,
        json string on successful response;
        hashref on error response;

=cut

sub delete_lead {
    my ($self, $lead_id) = @_;

    die 'Missing lead_id.' unless $lead_id;

    my $response = $self->http->request('DELETE', $self->config->{api_url} . "lead/$lead_id/");

    return $response->{content} if $response->{success};
    return $response;
}

1;
