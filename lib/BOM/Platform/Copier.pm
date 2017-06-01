package BOM::Platform::Copier;

use strict;
use warnings;

use BOM::Database::AutoGenerated::Rose::Copier::Manager;

use base 'BOM::Database::AutoGenerated::Rose::Copier';

sub rnew { return shift->SUPER::new(@_) }

sub new {
    my $class = shift;
    my $args = shift || die 'BOM::Platform::Copier->new called without args';

    my $operation = delete $args->{db_operation};

    my $self = $class->SUPER::new(%$args);

    $self->set_db($operation) if $operation;

    $self->load(speculative => 1) || return;    # must exist in db
    return $self;
}

sub update_or_create {
    my $class = shift;
    my $args  = shift;

    BOM::Database::AutoGenerated::Rose::Copier::Manager->delete_copiers(
        db => BOM::Database::ClientDB->new({
                broker_code => $args->{broker},
                operation   => 'write',
            }
            )->db,
        where => [
            trader_id => $args->{trader_id},
            copier_id => $args->{copier_id},
        ],
    );

    for my $p (qw/assets trade_types/) {
        $args->{$p} = [$args->{$p}] if ref $args->{$p} ne 'ARRAY';
        $args->{$p} = ['*'] unless grep { defined } @{$args->{$p}};
    }

    for my $asset (@{$args->{assets}}) {
        for my $trade_type (@{$args->{trade_types}}) {
            my $self = $class->rnew(
                broker          => $args->{broker},
                trader_id       => $args->{trader_id},
                copier_id       => $args->{copier_id},
                min_trade_stake => $args->{min_trade_stake},
                max_trade_stake => $args->{max_trade_stake},
                trade_type      => $trade_type,
                asset           => $asset,
            )->save;
        }
    }

    return;
}

sub save {
    my $self = shift;

    $self->set_db('write');
    return $self->SUPER::save;    # Rose
}

1;
