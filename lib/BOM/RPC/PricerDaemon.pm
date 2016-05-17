package BOM::RPC::PricerDaemon;

use strict;
use warnings;

use Carp;
use JSON::XS qw(encode_json decode_json);
use BOM::RPC::v3::Contract;
use BOM::System::RedisReplicated;
use DataDog::DogStatsd::Helper;
use Time::HiRes qw(gettimeofday);
use utf8;

sub new {
    my ($class, @args) = @_;

    my $self;
    if (ref $args[0]) {
        $self = $args[0];
    } else {
        $self = {@args};
    }

    my @REQUIRED = qw(data key);

    my @missing = grep { !$self->{$_} } @REQUIRED;
    croak "Error, missing parameters: " . join(',', @missing) if @missing;

    bless $self, $class;
    $self->_initialize();
    return $self;
}

sub _initialize {
    my $self = shift;

    my $args = {};

    $self->{params} = {@{JSON::XS::decode_json($self->{data})}};

    $pickup_time = gettimeofday;
    DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.price.pickup_delay', $pickup_time - $self->{request_time});
    delete $self->{request_time};

    my $r = BOM::Platform::Context::Request->new({language => $self->{params}->{language}});

    BOM::Platform::Context::request($r);
    return;
}

sub price {
    my $self = shift;

    my $response = BOM::RPC::v3::Contract::send_ask({args => $self->{params}});

    delete $response->{longcode};

    DataDog::DogStatsd::Helper::stats_inc('pricer_daemon.price.call');
    DataDog::DogStatsd::Helper::stats_timing('pricer_daemon.price.time', $response->{rpc_time});

    $response->{data} = $self->{data};
    $response->{key}  = $self->{key};
    return encode_json($response);
}

1;
