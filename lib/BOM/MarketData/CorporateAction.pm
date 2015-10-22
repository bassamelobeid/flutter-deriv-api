package BOM::MarketData::CorporateAction;

use BOM::System::Chronicle;

=head1 NAME

BOM::MarketData::CorporateAction

=head1 DESCRIPTION

Represents the corporate actions data of an underlying from chronicle
$corp = BOM::MarketData::CorporateAction->new(symbol => $symbol);

=cut

use Moose;

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

    return ($self->actions) ? $self->actions : {};
}

sub save {
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

    BOM::System::Chronicle->add('corporate_actions', $self->symbol, %all_actions);
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

    return BOM::System::Chronicle->get("corporate_actions", $self->symbol) // {};
}

sub new_actions {
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

sub cancelled_actions {
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
