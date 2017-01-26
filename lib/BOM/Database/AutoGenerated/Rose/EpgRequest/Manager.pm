package BOM::Database::AutoGenerated::Rose::EpgRequest::Manager;

use strict;

use base qw(Rose::DB::Object::Manager);

use BOM::Database::AutoGenerated::Rose::EpgRequest;

sub object_class { 'BOM::Database::AutoGenerated::Rose::EpgRequest' }

__PACKAGE__->make_manager_methods('epg_request');

1;

