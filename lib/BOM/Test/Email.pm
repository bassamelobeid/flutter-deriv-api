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

sub get_email_by_address_subject {
    my %cond = @_;

    die 'Need email address and subject regexp' unless $cond{email} && $cond{subject} && ref($cond{subject}) eq 'Regexp';

    my $email          = $cond{email};
    my $subject_regexp = $subject;

    my $mgr = Mail::Box::Manager->new;
    my ($folder, %msg);
    #mailbox maybe late, so we wait 3 seconds
    WAIT: for (0 .. 5) {
        $folder = $mgr->open(
            folder => $mailbox,
        );

        MSG: for my $tmsg ($folder->messages) {
            my @to      = $tmsg->to;
            my $address = $to[0]->address();
            my $subject = $tmsg->subject();

            if ($address eq $email && $subject =~ $subject_regexp) {
                $msg{body}    = $tmsg->body->decoded();
                $msg{address} = $address;
                $msg{subject} = $subject;
                last WAIT;
            }
        }
        $folder->close();
        sleep 1;
    }
    return %msg;
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

1;

