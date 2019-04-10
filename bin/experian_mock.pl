#!/usr/bin/env perl

=head2 Description

This is our mocked Experian server setup at http://localhost:4040

=cut

use strict;
use warnings;

use Mojolicious::Lite;
use List::Util;
use BOM::Config;
use Digest::SHA qw/hmac_sha256_base64/;

plugin "RenderFile";

my $entries = [map { "Experian$_" } qw(Valid InsufficientDOB Deceased OFSI PEP BOE Fault InsufficientUKGC)];

sub _generate_hash {
    my $timestamp = shift;

    my $username    = BOM::Config::third_party()->{proveid}->{username};
    my $password    = BOM::Config::third_party()->{proveid}->{password};
    my $private_key = BOM::Config::third_party()->{proveid}->{private_key};

    my $hash = hmac_sha256_base64($username, $password, $timestamp, $private_key);

    # Digest::SHA doesn't pad it's outputs so we have to do it manually.
    while (length($hash) % 4) {
        $hash .= '=';
    }

    return $hash;
}

sub _is_valid_2FA_sig {
    my $req_signature = shift;

    my ($req_hash, $timestamp, $req_public_key) = split(/_/, $req_signature);

    my $expected_hash       = _generate_hash($timestamp);
    my $expected_public_key = BOM::Config::third_party()->{proveid}->{public_key};

    return ($req_hash eq $expected_hash && $req_public_key eq $expected_public_key);
}

=pod

This mocks Experian's API behaviour. We return an xml that corresponds to the first name in the request.

=cut

post '/' => sub {
    my $self = shift;

    my $xml_req = $self->tx->req->body;

    $xml_req =~ /<head:Signature xsi:type="xsd:string">([^<]+)<\/head:Signature>/;

    my $signature = $1;

    if (_is_valid_2FA_sig($signature)) {
        $xml_req =~ /<Forename>([^>]+)<\/Forename>/;

        my $name = $1;

        my $path = "/home/git/regentmarkets/bom-test/data/Experian/ResponseXML/";

        $path .= (List::Util::any { $_ eq $name } @$entries) ? $name : "NotFound";
        $path .= '.xml';

        open(my $fh, '<', "$path");
        read $fh, my $file_content, -s $fh;

        $self->render(text => "$file_content");
    } else {
        my $path = "/home/git/regentmarkets/bom-test/data/Experian/ResponseXML/Invalid2FA.xml";

        open(my $fh, '<', "$path");
        read $fh, my $file_content, -s $fh;

        $self->render(text => "$file_content");
    }
};

=pod

These mock the Experian website login page

=cut

get '/signin' => 'form';

post '/signin/onsignin.cfm' => 'form';

=pod

This mocks the Experian link from which we use to download pdf reports from

=cut

get '/archive/index.cfm' => sub {
    my $self = shift;

    my $name = $self->req->params->param('id');

    my $path = "/home/git/regentmarkets/bom-test/data/Experian/PDF/";

    $path .= (List::Util::any { $_ eq $name } @$entries) ? $name : "NotFound";
    $path .= '.pdf';

    $self->render_file('filepath' => "$path");
};

app->start;

__DATA__
@@ form.html.ep
<!DOCTYPE html>
<html>
  <head><title>Upload</title></head>
  <body>
    <form>
      <input name="login" type="text">
      <input name="password" type="text">
      <input name="_CSRF_token" type="text" value="1">
      <input type="submit" value="Ok">
    </form>
  </body>
</html>
