package BOM::Product::Role::ExpireAtEnd;

use Moose::Role;

use Time::Duration::Concise;
use BOM::Platform::Context qw(localize);
use BOM::Utility::ErrorStrings qw( format_error_string );

sub _build_is_expired {
    my $self = shift;

    return 0 if (not $self->is_after_expiry);

    my $is_expired = 1;
    if ($self->exit_tick) {
        $self->check_expiry_conditions;
    } else {
        $self->value(0);
        $self->add_errors({
                severity => 100,
                message  => format_error_string(
                    'Missing settlement tick',
                    symbol => $self->underlying->symbol,
                    expiry => $self->date_expiry->datetime
                ),
                message_to_client => localize('The database is not yet updated with settlement data.'),
            });
    }
    return $is_expired;
}

1;
