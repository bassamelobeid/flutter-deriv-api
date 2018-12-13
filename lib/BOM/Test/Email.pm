package BOM::Test::Email;

use strict;
use warnings;

use Email::MIME;
use Email::Abstract;
use Email::Sender::Transport::Test;

our @EXPORT_OK = our @EXPORT = qw(mailbox_clear mailbox_search);

$ENV{EMAIL_SENDER_TRANSPORT} = 'Test';    ## no critic

=head2 mailbox_clear

Removes all existing messages from the mailbox.

=cut

sub mailbox_clear {
    email_list();
    return;
}

=head2 mailbox_check_empty

Verify whether the mailbox has any messages - will fail if any are found,
and as a side effect will clear the list.

=cut

sub mailbox_check_empty {
    return is(0 + email_list(), 0, 'have no emails to start with');
}

=head2 mailbox_search

Search through the mailbox for content.

Accepts named parameters:

=over 4

=item * C<email> - a C<To> address to locate

=item * C<subject> - subject to match (regex)

=item * C<body> - the body content to match (regex), will try to use
plain text if available.

=back

=cut

sub mailbox_search {
    my (%args) = @_;
    my @email = email_list();
    EMAIL:
    for my $msg (@email) {
        if (exists $args{email} and not grep { $_ eq $args{email} } @{$msg->{to}}) {
            next EMAIL;
        }
        if (exists $args{subject} and $msg->{subject} !~ $args{subject}) {
            next EMAIL;
        }
        if (exists $args{body} and $msg->{body} !~ $args{body}) {
            next EMAIL;
        }
        return $msg;
    }
    note explain \@email;
    return undef;
}

sub email_list {
    my $transport = Email::Sender::Simple->default_transport;
    my @emails =
        map { +{$_->{envelope}->%*, subject => '' . $_->{email}->get_header('Subject'), body => '' . $_->{email}->get_body,} } $transport->deliveries;
    $transport->clear_deliveries;
    return @emails;
}

1;

