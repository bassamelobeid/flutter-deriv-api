package BOM::Cryptocurrency::DynamicSettings;

use strict;
use warnings;

use Text::CSV;
use JSON::MaybeXS;

=head2 normalize_settings_data

Returns proper settings data to be displayed to the BO user.

Receives the following parameter:

=over 4

=item * C<settings> - A hashref containing the following keys:

=over 4

=item * C<revision>  - An epoch of the latest revision time.

=item * C<settings>  - A hashref of all cashier config keys, where each key is a hashref containing the following keys:

=over 4

=item * C<description>   - A string of the config key description.

=item * C<key_type>      - A string of the key type (dynamic or static).

=item * C<data_type>     - A string of the data type (Str, Num, Bool, ArrayRef, or json_string)

=item * C<default_value> - The default value of the config key.

=item * C<current_value> - The current value of the config key.

=back

=back

=back

Returns a hashref of the normalized settings data.

=cut

sub normalize_settings_data {
    my $settings   = shift;
    my $categories = {};

    for my $key (keys %{$settings->{settings}}) {
        my $description = $settings->{settings}{$key}{description};
        my $data_type   = $settings->{settings}{$key}{data_type};
        my $default     = $settings->{settings}{$key}{default_value};
        my $value       = $settings->{settings}{$key}{current_value};
        my $key_type    = $settings->{settings}{$key}{key_type};

        my $default_text = textify_obj($data_type, $default);
        my $value_text   = textify_obj($data_type, $value);
        #push it in right namespace
        my $space      = $categories;
        my @namespaces = split(/\./, $key);
        my $i          = 0;
        my $len        = scalar @namespaces;
        for my $name (@namespaces) {
            $i++;
            $name = $key if $len == $i;
            $space->{$name} //= {};

            $space = $space->{$name};
        }
        my $ds_leaf = {};
        $ds_leaf->{name}          = $key;
        $ds_leaf->{description}   = $description;
        $ds_leaf->{type}          = $data_type;
        $ds_leaf->{value}         = $value_text;
        $ds_leaf->{default}       = $value_text eq $default_text;
        $ds_leaf->{default_value} = $default_text;
        $ds_leaf->{disabled}      = $key_type ne 'dynamic' ? 1 : 0;
        $space->{leaf}            = $ds_leaf;
    }

    return {
        settings         => $categories,
        setting_revision => $settings->{revision},
    };
}

=head2 render_save_dynamic_settings_response

Render the crypto API response of saving the dynamic settings.

Receives the following parameter:

=over 4

=item * C<response> - A hashref contains the following keys:

=over 4

=item * C<error_message>    - A string of the error message if fail to update the settings.

=item * C<success>          - 1 if updated successfully otherwise 0.

=item * C<updated_settings> - A hash reference of the submitted settings keys, where each key contain:

=over 4

=item * C<valid>  - 1 if the key is exists and its value is valid, 0 otherwise.

=item * C<value>  - The submitted key value.

=item * C<remark> - A string of the error message if it is invalid.

=back

=back

=item * C<settings> - The crypto cashier dynamic settings. It's needed to get the data type of the config key.

=back

=cut

sub render_save_dynamic_settings_response {
    my ($response, $settings) = @_;

    my $message = "";
    unless ($response->{success}) {
        $message .= '<div class="notify notify--warning">FAILED to save global' . '<br />' . $response->{error_message} . '<br />' . '</div>';
    } else {
        $message .= '<p class="notify center">Saved global settings to environment.</p>';
    }

    if (keys %{$response->{updated_settings}}) {
        $message .= qq~
            <table id="settings_summary" class="collapsed hover border center">
                <thead><tr><th>Validation</th><th>Key Name</th><th>New Value</th><th>Remark</th></tr></thead>~;

        for my $key (keys %{$response->{updated_settings}}) {
            unless ($response->{updated_settings}{$key}{valid}) {
                $message .= join('',
                    '<tr class="error"><td class="status">&#10005;</td><td class="key-name">',
                    $key,
                    '</td><td class="value">',
                    $response->{updated_settings}{$key}{value},
                    '</td><td>', $response->{updated_settings}{$key}{remark}, '</td></tr>');
            } else {
                my $display_value = get_display_value($response->{updated_settings}{$key}{value}, $settings->{settings}{$key}{data_type});
                $message .= join('',
                    '<tbody><tr class="saved"><td class="status">&#10004;</td><td class="key-name">',
                    $key,           '</td><td class="value">',
                    $display_value, '</td><td>-</td></tr>');
            }
        }

        $message .= '</tbody></table>';
    }

    print $message;
}

=head2 textify_obj

Returns a serialized value if it's an ArrayRef, otherwise, return the value as-is.

Takes the following parameters:

=over 4

=item * C<$type>  - A string of the data type.

=item * C<$value> - The value to convert.

=back

=cut

sub textify_obj {
    my ($type, $value) = @_;
    return ($type eq 'ArrayRef') ? join(',', @$value) : $value;
}

=head2 get_display_value

Returns a normalized value to display based on the data type.

Takes the following parameters:

=over 4

=item * C<$input_value> - The value to normalize.

=item * C<$type>        - A string of the data type.

=back

=cut

sub get_display_value {
    my ($input_value, $type) = @_;

    # Trim
    $input_value =~ s/^\s+//  if (defined($input_value));
    $input_value =~ s/\s+$//g if (defined($input_value));

    my $display_value = $input_value;

    if ($type eq 'Bool') {
        if (not defined $input_value or ($input_value =~ /^(no|n|0|false)$/i)) {
            $display_value = 'false';
        } elsif ($input_value =~ /^(yes|y|1|true|on)$/i) {
            $display_value = 'true';
        }
    } elsif ($type eq 'ArrayRef') {
        if (ref($input_value) eq 'ARRAY') {
            $display_value = join(',', @{$input_value});
        } elsif (not defined($input_value) or not length($input_value)) {
            $display_value = '';
        } elsif ($input_value =~ /,/) {
            my $csv = Text::CSV->new;
            $input_value =~ s/, /,/g;    # in case of: 'val1, val2, etc'
            if ($csv->parse($input_value)) {
                $input_value = [$csv->fields()];
                $csv->combine(@$input_value);
                $display_value = $csv->string;
            }
        } else {
            $input_value   = [split(/\s+/, $input_value)];
            $display_value = join(', ', @$input_value);
        }
    } elsif ($type eq 'json_string') {
        if (defined $input_value) {
            my $decoded = JSON::MaybeXS->new->decode($input_value);
            $display_value = JSON::MaybeXS->new(
                pretty    => 1,
                canonical => 1,
            )->encode($decoded);
        }
    }

    $display_value = $input_value /= 1 if $type eq 'Num' || $type eq 'Int';    # cast string into a num scalar.

    return $display_value;
}

1;
