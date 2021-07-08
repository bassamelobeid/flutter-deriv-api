package BOM::RPC::v3::Services::Onramp;

=head1 NAME

BOM::RPC::v3::Services::Banxa

=head1 DESCRIPTION

This module provides a function to create orders for various external onramp services.

=cut

use strict;
use warnings;

use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use Digest::SHA qw(hmac_sha256_hex);
use Net::Async::HTTP;
use BOM::Platform::Context qw(localize);
use BOM::RPC::v3::Services::Crypto;
use BOM::RPC::v3::Utility;
use BOM::Config;
use LandingCompany::Registry;

=head2 new

Constructor. Supported arguments:

=over 4

=item * C<service>: name of onframp service

=back

=cut

sub new {
    my ($class, %params) = @_;
    die unless ($params{service} // '') =~ /^(banxa|wyre)$/;
    return bless \%params, shift;
}

=head2 service

Returns the onramp service name

=cut

sub service { shift->{service} }

=head2 loop

Returns IO::Async::Loop instance.

=cut

sub loop {
    my $self = shift;
    return $self->{loop} //= IO::Async::Loop->new();
}

=head2 http_client

Returns Net::Async::HTTP instance.

=cut

sub http_client {
    my $self = shift;
    return $self->{http_client} //= do {
        $self->loop->add(my $http_client = Net::Async::HTTP->new());
        $http_client;
    };
}

=head2 config

Gets api configuration.

=cut

sub config {
    my $self = shift;
    return $self->{config} //= BOM::Config::third_party()->{$self->service};
}

=head2 create_order

Creates a new order for the current onramp service.

Returns a Future.

=over 4

=item * C<params> - RPC params

=back

=cut

sub create_order {
    my ($self, $params) = @_;

    return Future->done({error => BOM::RPC::v3::Utility::permission_error()}) if ($params->{source_type} // '') ne 'official';

    my $client   = $params->{client};
    my $currency = $client->currency // '';

    return Future->done({
            error => BOM::RPC::v3::Utility::create_error({
                    code              => 'OrderCreationError',
                    message_to_client => localize('This feature is only available for accounts with crypto as currency.'),
                })}) if (not $currency or (LandingCompany::Registry::get_currency_type($currency) // '') ne 'crypto');

    my $f;
    if ($self->service eq 'banxa') {
        $f = $self->_banxa_order($params);
    } elsif ($self->service eq 'wyre') {
        $f = $self->_wyre_reservation($params->{client});
    }

    return $f->catch(
        sub {
            my ($exception) = @_;
            return Future->done({
                    error => BOM::RPC::v3::Utility::create_error({
                            code              => 'ConnectionError',
                            message_to_client => $exception,
                        })});
        });
}

=head2 _banxa_order

Creates a Banxa order.

Returns a Future.

=cut

sub _banxa_order {
    my ($self, $params) = @_;

    my $referrer = $params->{args}{referrer} // $params->{referrer};
    my $client   = $params->{client};
    my $config   = $self->config;

    my $data = {
        account_reference     => $client->loginid,
        return_url_on_success => $referrer,
        source                => "USD",
        target                => $client->currency,
        wallet_address        => _get_crypto_deposit_address($client->loginid),
    };

    my $content  = encode_json_utf8($data);
    my $endpoint = '/api/orders';
    my $epoch    = time;
    my $payload  = join("\n", 'POST', $endpoint, $epoch, $content);

    $self->http_client->configure(
        +headers => {Authorization => 'Bearer ' . $config->{api_key} . ':' . hmac_sha256_hex($payload, $config->{api_secret}) . ':' . $epoch});

    return $self->http_client->POST($self->config->{api_url} . $endpoint, $content, content_type => 'application/json')->then(
        sub {
            my ($result) = @_;
            my $response = decode_json_utf8($result->content);

            return Future->done({
                    error => BOM::RPC::v3::Utility::create_error({
                            code              => 'OrderCreationError',
                            message_to_client => localize('Cannot create a Banxa order for [_1]', $client->loginid),
                        })}) if $response->{errors};

            return Future->done({
                url   => $response->{data}{order}{checkout_url},
                token => $response->{data}{order}{id},
            });
        });
}

=head2 _wyre_reservation

Creates a Wyre reservation.

Returns a Future.

=cut

sub _wyre_reservation {
    my ($self, $client) = @_;

    my $config = $self->config;

    my $data = {
        referenceId       => $client->currency,
        sourceCurrency    => 'USD',
        destCurrency      => $client->currency,
        country           => $client->residence,
        referrerAccountId => $config->{api_account_id},
        dest              => _get_crypto_deposit_address($client->loginid),
        lockFields        => ["destCurrency", "country"],
    };

    my $content = encode_json_utf8($data);
    $self->http_client->configure(+headers => {Authorization => 'Bearer ' . $config->{api_secret}});

    return $self->http_client->POST($config->{api_url} . '/v3/orders/reserve', $content, content_type => 'application/json')->then(
        sub {
            my ($result) = @_;
            my $response = decode_json_utf8($result->content);
            return Future->done({
                    error => BOM::RPC::v3::Utility::create_error({
                            code              => 'OrderCreationError',
                            message_to_client => localize('Cannot create a Wyre reservation for [_1]', $client->loginid),
                        })}) if $response->{errorCode};

            return Future->done({
                    token => $response->{reservation},
                    url   => $response->{url}});
        });
}

=head2 _get_crypto_deposit_address

Get the deposit address for crypto.

Takes the following parameter:

=over 4

=item * C<$loginid> - The client loginid

=back

Returns the deposit address or an empty string if there was an error.

=cut

sub _get_crypto_deposit_address {
    my ($loginid) = @_;

    my $crypto_service = BOM::RPC::v3::Services::Crypto->new();
    my $deposit_result = $crypto_service->deposit($loginid);
    return $deposit_result->{deposit}{address} // '';
}

1;
