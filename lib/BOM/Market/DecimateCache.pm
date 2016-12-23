package BOM::Market::DecimateCache;

use strict;
use warnings;

use 5.010;
use Moose;

use RedisDB;
use Date::Utility;
use Sereal::Encoder;
use Sereal::Decoder;
use Data::Decimate qw(decimate);

use BOM::System::RedisReplicated;

=head1 NAME

BOM::Market::DecimateCache - A module that works with redis for decimated datas. 

=head1 SYNOPSIS

  use BOM::Market::DecimateCache;

=head1 DESCRIPTION

A module that allows you to retrieve a decimated data feed from redis.

=cut

=head1 ATTRIBUTES
=cut

=head2 sampling_frequency

=head2 data_cache_size

=head2 decimate_cache_size

=cut

has sampling_frequency => (
    is      => 'ro',
    isa     => 'time_interval',
    default => '15s',
    coerce  => 1,
);

# size is the number of ticks
has data_cache_size => (
    is      => 'ro',
    default => 1860,
);

has decimate_cache_size => (
    is      => 'ro',
    default => 2880,
);

has decimate_retention_interval => (
    is      => 'ro',
    isa     => 'time_interval',
    lazy    => 1,
    coerce  => 1,
    builder => '_build_decimate_retention_interval',
);

sub _build_decimate_retention_interval {
    my $self = shift;
    my $interval = int($self->decimate_cache_size / (60 / $self->sampling_frequency->seconds));
    return $interval . 'm';
}

has raw_retention_interval => (
    is      => 'ro',
    isa     => 'time_interval',
    lazy    => 1,
    coerce  => 1,
    builder => '_build_raw_retention_interval',
);

sub _build_raw_retention_interval {
    my $interval = int(shift->data_cache_size / 60);
    return $interval . 'm';
}

has decoder => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_decoder',
);

sub _build_decoder {
    return Sereal::Decoder->new;
}

has encoder => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_encoder',
);

sub _build_encoder {
    return Sereal::Encoder->new({
        canonical => 1,
    });
}

has 'redis_read' => (
    is      => 'ro',
    default => sub {
        BOM::System::RedisReplicated::redis_read();
    },
);

has 'redis_write' => (
    is      => 'ro',
    default => sub {
        BOM::System::RedisReplicated::redis_write();
    },
);

=head1 SUBROUTINES/METHODS

=head2 _make_key

=cut

sub _make_key {
    my ($self, $symbol, $decimate) = @_;

    my @bits = ("AGGTICKS", $symbol);
    if ($decimate) {
        push @bits, ($self->sampling_frequency->as_concise_string, 'AGG');
    } else {
        push @bits, ($self->raw_retention_interval->as_concise_string, 'FULL');
    }

    return join('_', @bits);
}

=head2 _update

=cut 

sub _update {
    my ($self, $redis, $key, $score, $value) = @_;

    return $redis->zadd($key, $score, $value);
}

=head2 decimate_cache_get

=cut

sub decimate_cache_get {
    my ($self, $args) = @_;

    my $which = $args->{symbol}      // '';
    my $start = $args->{start_epoch} // 0;
    my $end   = $args->{end_epoch}   // time;

    my $redis = $self->redis_read;

    my @res;
    my $key = $self->_make_key($which, 1);

    @res = map { $self->decoder->decode($_) } @{$redis->zrangebyscore($key, $start, $end)};

    my @sorted = sort { $a->{epoch} <=> $b->{epoch} } @res;

    return \@sorted;
}

my %prev_added_epoch;

=head2 data_cache_get

Retrieve datas from start epoch till end epoch .

=cut

sub data_cache_get {
    my ($self, $args) = @_;
    my $symbol = $args->{symbol};
    my $start  = $args->{start_epoch} // 0;
    my $end    = $args->{end_epoch} // time;

    my @res = map { $self->decoder->decode($_) } @{$self->redis_read->zrangebyscore($self->_make_key($symbol, 0), $start, $end)};

    return \@res;
}

=head2 data_cache_get_num_data

Retrieve num number of data from DataCache.

=cut

sub data_cache_get_num_data {

    my ($self, $args) = @_;

    my $symbol = $args->{symbol};
    my $end    = $args->{end_epoch} // time;
    my $num    = $args->{num} // 1;

    my @res;

    @res = map { $self->decoder->decode($_) } reverse @{$self->redis_read->zrevrangebyscore($self->_make_key($symbol, 0), $end, 0, 'LIMIT', 0, $num)};

    return \@res;
}

=head2 data_cache_insert

Also insert into decimate cache if data crosses 15s boundary.

=cut

sub data_cache_insert {
    my ($self, $data) = @_;

    $data = $data->as_hash if blessed($data);

    my %to_store = %$data;

    $to_store{count} = 1;    # These are all single data;
    my $key          = $self->_make_key($to_store{symbol}, 0);
    my $decimate_key = $self->_make_key($to_store{symbol}, 1);

    # check for resample interval boundary.
    my $current_epoch = $data->{epoch};
    my $prev_added_epoch = $prev_added_epoch{$to_store{symbol}} // $current_epoch;

    my $boundary = $current_epoch - ($current_epoch % $self->sampling_frequency->seconds);

    if ($current_epoch > $boundary and $prev_added_epoch <= $boundary) {
        if (
            my @datas =
            map { $self->decoder->decode($_) }
            @{$self->redis_read->zrangebyscore($key, $boundary - $self->sampling_frequency->seconds - 1, $boundary)})
        {
            #do resampling
            my $decimate_data = Data::Decimate::decimate($self->sampling_frequency->seconds, \@datas);

            foreach my $tick (@$decimate_data) {
                $self->_update($self->redis_write, $decimate_key, $tick->{decimate_epoch}, $self->encoder->encode($tick));
            }
        } elsif (
            my @decimate_data = map {
                $self->decoder->decode($_)
            } reverse @{
                $self->redis_read->zrevrangebyscore(
                    $self->_make_key($to_store{symbol}, 1),
                    $boundary - $self->sampling_frequency->seconds,
                    0, 'LIMIT', 0, 1
                )})
        {
            my $single_data = $decimate_data[0];
            $single_data->{decimate_epoch} = $boundary;
            $single_data->{count}          = 0;
            $self->_update(
                $self->redis_write,
                $self->_make_key($to_store{symbol}, 1),
                $single_data->{decimate_epoch},
                $self->encoder->encode($single_data));
        }
    }

    $prev_added_epoch{$to_store{symbol}} = $current_epoch;

    return $self->_update($self->redis_write, $key, $data->{epoch}, $self->encoder->encode(\%to_store));
}

=head1 AUTHOR

Binary.com, C<< <support at binary.com> >>

=cut

no Moose;

__PACKAGE__->meta->make_immutable;

1;
