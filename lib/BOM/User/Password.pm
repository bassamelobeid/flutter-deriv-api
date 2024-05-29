package BOM::User::Password;
use strict;
use warnings;

use BOM::Service::User::Transitional::Password;
use BOM::Service::User::Attributes;

use Log::Any qw($log);

=head1 NAME

BOM::User::Password - Password hashing module for BOM, this functionality has been moved
to BOM::Service::User::Password and will vanish in the future into the user service itself

=cut

sub hashpw {
    BOM::Service::User::Attributes::trace_caller();
    return BOM::Service::User::Transitional::Password::hashpw(@_);
}

sub checkpw {
    BOM::Service::User::Attributes::trace_caller();
    return BOM::Service::User::Transitional::Password::checkpw(@_);
}

1;
