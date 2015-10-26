package mock;

use strict;
use warnings;

use Test::MockModule;

sub email {
    my $m = Test::MockModule->new('Mail::Sender');
    $m->mock(
        new => sub {
            shift;
            return mock::Email->new(@_);
        });
    return $m;
}

package mock::Email;

sub new {
    shift;
    my $self = bless {}, __PACKAGE__;
    push @{$self->{new}}, [@_];

    Test::More::note "sending email";

    return $self;
}

sub MailFile {
    my $self = shift;
    push @{$self->{new}}, [@_];
    return $self;
}

sub MailMsg {
    my $self = shift;
    push @{$self->{new}}, [@_];
    return $self;
}

sub Open {
    my $self = shift;
    push @{$self->{new}}, [@_];
    return $self;
}

sub SendEnc {
    my $self = shift;
    push @{$self->{new}}, [@_];
    return $self;
}

sub Close {
    my $self = shift;
    push @{$self->{new}}, [@_];
    return $self;
}

1;
