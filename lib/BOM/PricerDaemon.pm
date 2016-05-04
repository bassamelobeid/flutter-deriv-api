package BOM::PricerDaemon;
use strict;
use warnings;

use Carp;
use JSON::XS qw(encode_json decode_json);
use BOM::RPC::v3::Contract;

sub new {
    my $class = shift;
    my $self = ref $_[0] ? $_[0] : {@_};

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
    my $r = BOM::Platform::Context::Request->new({language=>$self->{params}->{language}});
    BOM::Platform::Context::request($r);
}

sub price {
    my $self = shift;

    my $response = BOM::RPC::v3::Contract::send_ask($self->{params}->{pricing_args});

    return encode_json($response);
}
    
}


1;
