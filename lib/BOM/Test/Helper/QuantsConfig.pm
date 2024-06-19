package BOM::Test::Helper::QuantsConfig;

use strict;
use warnings;

use Exporter qw( import );
use BOM::Database::QuantsConfig;

our @EXPORT_OK = qw( create_config delete_all_config);

sub create_config {
    my $args = shift;

    return BOM::Database::QuantsConfig->new->set_global_limit($args);
}

sub delete_all_config {
    BOM::Database::QuantsConfig->new->_db_list('svg')->[0]->dbic->run(
        fixup => sub {
            $_->do(
                'DELETE FROM betonmarkets.symbol_global_potential_loss; DELETE FROM betonmarkets.symbol_global_potential_loss_market_defaults; DELETE from betonmarkets.market_global_potential_loss'
            );
            $_->do(
                'DELETE FROM betonmarkets.symbol_global_realized_loss; DELETE FROM betonmarkets.symbol_global_realized_loss_market_defaults; DELETE from betonmarkets.market_global_realized_loss'
            );
        });
    return;
}
1;
