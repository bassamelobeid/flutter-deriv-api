package BOM::RPC::PricerDaemon;

use strict;
use warnings;

use Carp;
use JSON::XS qw(encode_json decode_json);
use BOM::RPC::v3::Contract;

sub new {
    my ($class, @args) = @_;

    my $self;
    if (ref $args[0]) {
        $self = $args[0];
    } else {
        $self = {@args};
    }

    my @REQUIRED = qw(data);

    my @missing = grep { !$self->{$_} } @REQUIRED;
    croak "Error, missing parameters: " . join(',', @missing) if @missing;

    bless $self, $class;
    $self->_initialize();
    return $self;
}

sub _initialize {
    my $self = shift;

    my $args = {};

    $self->{params} = JSON::XS::decode_json($self->{data});
    my $r = BOM::Platform::Context::Request->new({language => $self->{params}->{language}});
    BOM::Platform::Context::request($r);
    return;
}

sub price {
    my $self = shift;

    my $response = BOM::RPC::v3::Contract::send_ask($self->{params});

    return encode_json($response);
}

1;
