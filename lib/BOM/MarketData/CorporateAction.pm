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

A string whcih represents underlying symbol (company name) for which we are going to load/save actions (e.g. USPG)
It is read-only (Cannot be changed after the object is instantieted) and required.

=cut

has symbol => (
    is       => 'ro',
    required => 1,
);

=head2 save

Save actions for current symbol into Database. It will process actions before saving.
This processing includes adding existing actions (stored in the database) and adding "new_actions" to them.
Also deleting "cancelled_actions" from the result.
We do this because we will be overwriting currently persistent data so we will need to re-construct the whole data structure.

=cut

sub save {
    my $self = shift;

    my %new_actions = %{$self->new_actions};
    my %existing_actions = $self->actions // {};

    delete $new_actions{$_}{flag} for keys %new_actions;

    #merge existing_actions and new_actions.
    my %all_actions;
    if (%existing_actions and %new_actions) {
        %all_actions = (%existing_actions, %new_actions);
    } elsif (%existing_actions xor %new_actions) {
        %all_actions = (%existing_actions) ? %existing_actions : %new_actions;
    }

    #delete cancelled actions from the result dataset
    foreach my $cancel_id (keys %{$self->cancelled_actions}) {
        delete $all_actions{$cancel_id};
    }

    BOM::System::Chronicle->add('corporate_actions', $self->symbol, %all_actions);
}

=head2 actions

An hash reference of corporate actions. 

=cut

has actions => (
    is         => 'ro',
    lazy_build => 1
);

sub _build_actions {
    my $self = shift;

    return \BOM::System::Chronicle->get("corporate_actions", $self->symbol) // {};
}

=head2 action_exists

Boolean. Returns true if action exists, false otherwise.

=cut

sub action_exists {
    my ($self, $id) = @_;

    return $self->actions->{$id} ? 1 : 0;
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
