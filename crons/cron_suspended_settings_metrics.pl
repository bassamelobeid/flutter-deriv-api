use strict;
use warnings;
no indirect;

=head2 report suspended settings

This module sends metrics to DataDog about suspended settings in the backoffice
to avoid forgetting about re-enabling them.

Each setting has a key called C<_local_rev> which is used to determine when the
key was set, we use that key to calculate the age of the key.

=cut

use BOM::Config::Runtime;
use BOM::DynamicSettings;
use DataDog::DogStatsd::Helper qw(stats_timing);

my $app_config        = BOM::Config::Runtime->instance->app_config;
my @suspend_keys_list = BOM::DynamicSettings::get_settings_by_group('shutdown_suspend')->@*;

# Skip local cache and get objects from chronicle
my @suspend_settings = $app_config->_retrieve_objects_from_chron(\@suspend_keys_list);

# Remove all suspend settings that are not set, return a key => settings hash
my %active_settings = map { $suspend_keys_list[$_] => $suspend_settings[$_] } grep { is_active($suspend_settings[$_]) } 0 .. $#suspend_keys_list;

# _local_rev is the time the value was set
stats_timing("suspended.settings.$_", time - $active_settings{$_}{_local_rev}) for keys %active_settings;

=head2 is_active

Check if a setting is active, expects data with the following format:

    {
        data => [value]
    }

where value is either a scalar or a ref.  A setting is active if the value of
C<data> is true. In case of ref it is dereferenced to check if the value is true.

=cut

sub is_active {
    # Not active if the key is not set
    return 0 unless my $settings = shift;

    # Not active if the data is false
    return 0 unless my $data = $settings->{data};

    if (ref $data) {
        # Not active if data has no item
        return 0 unless $data->@*;
    }

    return 1;
}

1;
