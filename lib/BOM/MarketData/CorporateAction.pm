package BOM::MarketData::CorporateAction;

use BOM::System::Chronicle;

=head1 NAME

BOM::MarketData::CorporateAction

=head1 DESCRIPTION

Represents the corporate actions data of an underlying from database. To read actions for a company:

 my $corp = BOM::MarketData::CorporateAction->new(symbol => $symbol);
 my $actions = $corp->actions;


To save actions for a company:

 my $corp = BOM::MarketData::CorporateAction->new(symbol => $symbol, 
                                                    actions => {
                                                        1234 => {
                                                            monitor_date => "2014-02-07",
                                                            type => "ACQUIS",
                                                            description => "Acquisition",
                                                            effective_date => "15-Jul-15",
                                                            flag => "N", #N means new action, U means updated action, D means cancelled action
                                                        }});
 $corp->save();

=cut

use Moose;
extends 'BOM::MarketData';    #we keep this as its not related to CouchDB

=head1 ATTRIBUTES

=head2 for_date

The date for which we wish data

=cut

has for_date => (
    is      => 'ro',
    isa     => 'Maybe[Date::Utility]',
    default => undef,
);

=head2 symbol

Represents underlying symbol

=cut

has symbol => (
    is       => 'ro',
    required => 1,
);

has _existing_actions => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__existing_actions {
    my $self = shift;

    return {} if not defined $self->document;

    return ($self->document->{actions}) ? $self->document->{actions} : {};
}

around _document_content => sub {
    my $orig = shift;
    my $self = shift;

    my %new              = %{$self->new_actions};
    my %existing_actions = %{$self->_existing_actions};

    my %new_act;
    foreach my $id (keys %new) {
        my %copy = %{$new{$id}};
        delete $copy{flag};
        $new_act{$id} = \%copy;
    }

    # updates existing actions and adds new actions
    my %all_actions;
    if (%existing_actions and %new_act) {
        %all_actions = (%existing_actions, %new_act);
    } elsif (%existing_actions xor %new_act) {
        %all_actions = (%existing_actions) ? %existing_actions : %new_act;
    }

    foreach my $cancel_id (keys %{$self->cancelled_actions}) {
        delete $all_actions{$cancel_id};
    }

    return {
        %{$self->$orig},
        actions => \%all_actions,
    };
};

has document => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_document {
    my $self = shift;

    my $document = BOM::System::Chronicle::get('corporate_actions', $self->symbol);

    if ($self->for_date and $self->for_date->datetime_iso8601 lt $document->{date}) {
        $document = BOM::System::Chronicle::get_for('corporate_actions', $self->symbol, $self->for_date->epoch);
    }

    return $document;
}

sub save {
    my $self = shift;

    return BOM::System::Chronicle::set('corporate_actions', $self->symbol, $self->_document_content);
}

=head2 actions

An hash reference of corporate reference for an underlying

=cut

has actions => (
    is         => 'ro',
    lazy_build => 1
);

sub _build_actions {
    my $self = shift;

    my $document = $self->document;

    return $document->{actions} if defined $document;
    return {};
}

=head2 action_exists
Boolean. Returns true if action exists, false otherwise.
=cut

sub action_exists {
    my ($self, $id) = @_;

    return $self->_existing_actions->{$id} ? 1 : 0;
}

has [qw(new_actions cancelled_actions)] => (
    is         => 'ro',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build_new_actions {
    my $self = shift;

    my %new;
    my $actions = $self->actions;
    foreach my $action_id (keys %$actions) {
        # flag 'N' = New & 'U' = Update
        my $action = $actions->{$action_id};
        if ($action->{flag} eq 'N' and not $self->action_exists($action_id)) {
            $new{$action_id} = $action;
        } elsif ($action->{flag} eq 'U') {
            $new{$action_id} = $action;
        }
    }

    return \%new;
}

sub _build_cancelled_actions {
    my $self = shift;

    my %cancelled;
    my $actions = $self->actions;
    foreach my $action_id (keys %$actions) {
        my $action = $actions->{$action_id};
        # flag 'D' = Delete
        if ($action->{flag} eq 'D' and $self->action_exists($action_id)) {
            $cancelled{$action_id} = $action;
        }
    }

    return \%cancelled;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
