package Common::UnitTestProduct;

use base qw(Rose::DB::Object);
use Rose::DB;

__PACKAGE__->meta->setup(
    table      => 'products',
    columns    => [qw(id name price)],
    pk_columns => 'id',
    unique_key => 'name',
);

sub init_db { Rose::DB->new(driver => 'SQLite',); }

=head1 DESCRIPTION

 This package exists only to test the BOM::Database::Model::Base package, independent of other model packages.

=head1 VERSION

0.1

=head1 AUTHOR

RMG Company

=cut

