package Commission::Helper::CTraderHelper;

use strict;
use warnings;

use HTTP::Tiny;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use Log::Any        qw($log);
use Net::Async::Redis;
use Syntax::Keyword::Try;
use Time::HiRes;
use YAML::XS qw(LoadFile);

=head1 NAME

Commission::Helper::CTraderHelper - Helper methods for cTrader related tasks

=head1 SYNOPSIS

    use Commission::Helper::CTraderHelper;

    my $ctrader_helper = Commission::Helper::CTraderHelper->new(redis => $redis);

    my $loginid = $ctrader_helper->get_loginid(server => 'real', traderIds => [1]);

    my $symbol = $ctrader_helper->get_underlying_symbol(dealId => 69);

    my $symbol_id = $ctrader_helper->get_symbolid_by_dealid(dealId => 360);

    my $symbol_json = $ctrader_helper->get_symbol_by_id(symbolId => 322);

=head1 DESCRIPTION

This module provides helper methods for cTrader related tasks.

=cut

use constant {
    HTTP_TIMEOUT => 20,
};

my ($redis, $ctrader_server);

=head2 new

Creates and returns a new L<Commission::Helper::CTraderHelper> instance.

=cut

sub new {
    my ($class, %args) = @_;

    $redis          = $args{redis};
    $ctrader_server = $args{server};

    return bless {%args, redis => $redis}, $class;
}

=head2 get_loginid

Returns the loginid of the given trader id.

=cut

sub get_loginid {
    my ($self, %args) = @_;

    my $result = $self->call_api(
        server  => $ctrader_server,
        method  => 'tradermanager_get',
        payload => {traderIds => $args{traderIds}});

    my $prefix = $ctrader_server eq 'real' ? 'CTR' : 'CTD';

    return $prefix . $result->[0]->{login};
}

=head2 get_underlying_symbol

Returns the underlying symbol of the given deal.

=cut

sub get_underlying_symbol {
    my ($self, %args) = @_;

    my $symbol_id = $self->get_symbolid_by_dealid(dealId => $args{dealId});

    my $symbol_json = $redis->hget("CTRADER::SYMBOL_LIST", $symbol_id)->get;

    # call get_symbol_by_id(symbolId) to set value for symbol_json if symbol_json is empty
    $symbol_json = $self->get_symbol_by_id(symbolId => $symbol_id) unless $symbol_json;

    my %symbol = %{decode_json_utf8($symbol_json)};

    return $symbol{symbol};
}

=head2 get_symbolid_by_dealid

Returns the symbolid of the given deal id.

=cut

sub get_symbolid_by_dealid {
    my ($self, %args) = @_;

    my $result = $self->call_api(
        server  => $ctrader_server,
        method  => 'ctradermanager_getdealbyid',
        payload => {dealId => $args{dealId}});

    return $result->{symbolId};
}

=head2 get_symbol_by_id

Returns the symbol name and quoted currency of the given symbol id.

=cut

sub get_symbol_by_id {
    my ($self, %args) = @_;

    my $symbol_id = $args{symbolId};

    # call cTrader get_symbol_by_id(symbolId)
    my $result = $self->call_api(
        server  => $ctrader_server,
        method  => 'ctradermanager_getsymbolbyid',
        payload => {symbolId => $symbol_id});

    # call cTrader get_asset_by_id(quotedAssetId)
    my $asset_result = $self->call_api(
        server  => $ctrader_server,
        method  => 'ctradermanager_getassetbyid',
        payload => {assetId => $result->{quoteAssetId}});
    $asset_result->{type} =~ s/^PROTO_//;    # Remove PROTO_ prefix from asset type

    # Save symbolId, symbol name and quoted currency to Redis hash
    my $symbol = {
        symbol   => $result->{name},
        currency => $asset_result->{name},
        type     => $asset_result->{type},
    };

    $redis->hset("CTRADER::SYMBOL_LIST", $symbol_id, encode_json_utf8($symbol))->get;

    return encode_json_utf8($symbol);
}

=head2 populate_symbol_list

Populate redis hash CTRADER::SYMBOL_LIST with symbol id and symbol name along quoted currency.

=cut

sub populate_symbol_list {
    my ($self, %args) = @_;

    my $result = $self->call_api(
        server => $ctrader_server,
        method => 'ctradermanager_getsymbollist'
    );

    foreach my $symbol (@$result) {
        my $symbol_id   = $symbol->{symbolId};
        my $symbol_name = $symbol->{name};

        my $asset = $self->call_api(
            server  => $ctrader_server,
            method  => 'ctradermanager_getassetbyid',
            payload => {assetId => $symbol->{quoteAssetId}});
        $asset->{type} =~ s/^PROTO_//;    # Remove PROTO_ prefix from asset type

        my $symbol = {
            symbol   => $symbol_name,
            currency => $asset->{name},
            type     => $asset->{type},
        };

        $redis->hset("CTRADER::SYMBOL_LIST", $symbol_id, encode_json_utf8($symbol))->get;
    }

}

=head2 handle_api_error

Called when an unexpcted cTrader API error occurs.

=cut

sub handle_api_error {
    my ($self, $resp, %args) = @_;

    $args{password} = '<hidden>'                            if $args{password};
    $resp           = [$resp->@{qw/content reason status/}] if ref $resp;
    $log->warnf('ctrader call failed for : %s, call args: %s', $resp, \%args);
}

=head2 http

Returns the current L<HTTP::Tiny> instance or creates a new one if neeeded.

=cut

sub http {
    return shift->{http} //= HTTP::Tiny->new(timeout => HTTP_TIMEOUT);
}

=head2 call_api

Calls API service with given params.

Takes the following named arguments, plus others according to the method.

=over 4

=item * C<server>. (Required) Server such as "real" or "demo"

=item * C<path>. Additional API path, at the current implementation, only "cid" or "trader".

=item * C<method>. (Required) Which API to call, example "trader_get"

=item * C<payload>. Additional data required by its corresponding API method calls. 

=item * C<quiet>. Don't die or log datadog stats when api returns error.

=back

=cut

sub call_api {
    my ($self, %args) = @_;

    my $config          = YAML::XS::LoadFile('/etc/rmg/ctrader_proxy_api.yml');
    my $ctrader_servers = {
        real => $config->{ctrader_live_proxy_url},
        demo => $config->{ctrader_demo_proxy_url}};

    my $server_url = $ctrader_servers->{$ctrader_server};
    $server_url .= $args{path} ? $args{path} : 'trader';

    my $quiet   = delete $args{quiet};
    my $headers = {
        'Content-Type' => "application/json",
    };
    my $payload = encode_json_utf8(\%args);

    my $resp;
    try {
        $resp = $self->http->post(
            $server_url,
            {
                content => $payload,
                headers => $headers
            });

        $resp->{content} = decode_json_utf8($resp->{content} || '{}');
        die unless $resp->{success} or $quiet;    # we expect some calls to fail, eg. client_get
        return $resp->{content};
    } catch ($e) {
        return $e if ref $e eq 'HASH';
        $self->handle_api_error($resp, %args);
    }
}

1;
