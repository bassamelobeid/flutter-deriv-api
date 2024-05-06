package BOM::User::Password;
use strict;
use warnings;

use BOM::Service::User::Transitional::Password;
use Log::Any qw($log);

=head1 NAME

BOM::User::Password - Password hashing module for BOM, this functionality has been moved
to BOM::Service::User::Password and will vanish in the future into the user service itself

=cut

sub hashpw {
    my ($package, $filename, $line) = caller(0);
    $log->warn("BOM::Service() - Call to BOM::User::Password::hashpw from outside of user service from: $package at $filename, line $line")
        unless BOM::Config::on_production();
    return BOM::Service::User::Transitional::Password::hashpw(@_);
}

sub checkpw {
    my ($package, $filename, $line) = caller(0);
    $log->warn("BOM::Service() - Call to BOM::User::Password::checkpw from outside of user service from: $package at $filename, line $line")
        unless BOM::Config::on_production();
    return BOM::Service::User::Transitional::Password::checkpw(@_);
}

1;
