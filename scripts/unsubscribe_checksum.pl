#!/usr/bin/env perl

use strict;
use warnings;
use Pod::Usage;

use BOM::User;
use BOM::User::Utility;
use BOM::Config;

my ($binary_user_id) = @ARGV;

=head1 NAME

unsubscribe_checksum.pl - create email unsubscribe checksum for the client

=head1 SYNOPSIS

unsubscribe_checksum.pl <binary_user_id>

=cut

pod2usage({
        -verbose => 99,
    }) if @ARGV != 1;

my $hash_key = BOM::Config::third_party()->{customerio}->{hash_key};
die "Hash key is not yet setted in /etc/rmg/third_party.yml\n" unless $hash_key;

print "Using hash_key as : $hash_key\n";

my $user = BOM::User->new(id => $binary_user_id);
die "cannot get the user, please try a different binary_user_id\n" unless $user;

my $checksum = BOM::User::Utility::generate_email_unsubscribe_checksum($binary_user_id, $user->email);

print "$checksum\n";
