package BOM::Platform::Client::Sanctions;

use strict;
use warnings;

use Moo;

use Brands;
use Data::Validate::Sanctions;
use BOM::Platform::Config;

has client => (
    is  => 'ro',
    isa => 'Client::Account'
);
has type => (
    is      => 'ro',
    default => 'R'
);

our $sanctions = Data::Validate::Sanctions->new(sanction_file => BOM::Platform::Config::sanction_file);

sub check {
    my $self   = shift;
    my $client = $self->client;

    return if $client->is_virtual;

    my $sanctioned = $sanctions->is_sanctioned($client->first_name, $client->last_name);
    $client->add_sanctions_check({
        type   => $self->type,
        result => $sanctioned
    });

    return unless $sanctioned;

    my $client_loginid = $client->loginid;
    my $client_name = join(' ', $client->salutation, $client->first_name, $client->last_name);

    $client->set_status('disabled', 'system', 'client disabled as marked as UNTERR');
    $client->save;
    $client->add_note('UNTERR', "UN Sanctions: $client_loginid suspected ($client_name)\n" . "Check possible match in UN sanctions list.");
    my $brand = Brands->new(name => request()->brand);
    send_email({
        from    => $brand->emails('support'),
        to      => $brand->emails('compliance'),
        subject => $client->loginid . ' marked as UNTERR',
        message => ["UN Sanctions: $client_loginid suspected ($client_name)\n" . "Check possible match in UN sanctions list."],
    });
    return;
}

1;
