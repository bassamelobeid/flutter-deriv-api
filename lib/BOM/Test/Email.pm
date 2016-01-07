package BOM::Test::Email;

=head1 NAME

BOM::Test::Email;

=head1 DESCRIPTION

Staff about email.

=head1 SYNOPSIS

    use BOM::Test::Email qw(get_email);

=cut

use strict;
use warnings;
use Mail::Box::Manager;
use base qw(Exporter);
our @EXPORT_OK = qw(get_email clear_mailbox);

our $mailbox = "/tmp/default.mailbox";

sub get_email {
    my %conditions = @_;

}

sub init {
    #init mailbox
    open(my $fh, ">$BddHelper::mailbox") || die "cannot create mailbox";
    close($fh);
    __PACKAGE__->export_to_level(1, @_);
}

sub clear_mailbox {
    truncate $mailbox, 0;
}
