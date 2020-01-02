package BOM::Event::Services;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

=head1 NAME

BOM::Event::Services - Construct required service objects

=head1 DESCRIPTION

This is helper to create service object required for
requesting data from various sources

=cut

use Net::Async::HTTP;
use Net::Async::Redis;
use WebService::Async::Onfido;
use WebService::Async::SmartyStreets;
use WebService::Async::Segment;

use BOM::Config;
use BOM::Config::RedisReplicated;

sub segment {
    my ($self) = @_;

    return $self->{segment} //= do {
        my %args = (
            write_key => $ENV{SEGMENT_WRITE_KEY} || BOM::Config::third_party()->{segment}->{write_key},
            base_uri  => $ENV{SEGMENT_BASE_URL}  || BOM::Config::third_party()->{segment}->{base_uri},
        );
        $self->add_child(my $service = WebService::Async::Segment->new(%args));
        $service;
        }
}

sub onfido {
    my ($self) = @_;
    return $self->{onfido} //= do {
        $self->add_child(
            my $service = WebService::Async::Onfido->new(
                token => BOM::Config::third_party()->{onfido}->{authorization_token} // 'test',
                $ENV{ONFIDO_URL} ? (base_uri => $ENV{ONFIDO_URL}) : ()));
        $service;
        }
}

sub smartystreets {
    my ($self) = @_;

    return $self->{smartystreets} //= do {
        $self->add_child(
            my $service = WebService::Async::SmartyStreets->new(
                international_auth_id => BOM::Config::third_party()->{smartystreets}->{auth_id},
                international_token   => BOM::Config::third_party()->{smartystreets}->{token},
            ));
        $service;
        }
}

sub http {
    my ($self) = @_;

    return $self->{http} //= do {
        $self->add_child(
            my $service = Net::Async::HTTP->new(
                fail_on_error  => 1,
                pipeline       => 0,
                decode_content => 1,
                stall_timeout  => 30,
                user_agent     => 'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:66.0)',
            ));
        $service;
        }
}

sub redis_mt5user {
    my ($self) = @_;

    return $self->{redis_mt5user} //= do {
        $self->add_child(my $service = Net::Async::Redis->new(uri => BOM::Config::RedisReplicated::redis_config('mt5_user', 'read')->{uri}));
        $service;
        }
}

sub redis_events_write {
    my ($self) = @_;

    return $self->{redis_events_write} //= do {
        my $redis_config = BOM::Config::RedisReplicated::redis_config('events', 'write');
        $self->add_child(
            my $service = Net::Async::Redis->new(
                uri  => $redis_config->{uri},
                auth => $redis_config->{password}));
        $service;
        }
}

sub redis_events_read {
    my ($self) = @_;

    return $self->{redis_events_read} //= do {
        my $redis_config = BOM::Config::RedisReplicated::redis_config('events', 'read');
        $self->add_child(
            my $service = Net::Async::Redis->new(
                uri  => $redis_config->{uri},
                auth => $redis_config->{password}));
        $service;
        }
}

sub redis_replicated_write {
    my ($self) = @_;

    return $self->{redis_replicated_write} //= do {
        my $redis_config = BOM::Config::RedisReplicated::redis_config('replicated', 'write');
        $self->add_child(
            my $service = Net::Async::Redis->new(
                uri  => $redis_config->{uri},
                auth => $redis_config->{password}));
        $service;
        }
}

1;

