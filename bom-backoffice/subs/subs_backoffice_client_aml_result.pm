## no critic (RequireExplicitPackage)
use strict;
use warnings;

use BOM::Platform::LexisNexisAPI;
use BOM::Database::UserDB;

=head1 subs_backoffice_client_aml_result

This module contains the subroutines related to client AML results.

=cut

=head2 lexis_nexis_results

    my $records = lexis_nexis_results($user_lexis_nexis_alert_id);

This subroutine is used to get the results from Lexis Nexis API for a given user lexis nexis alert id.

=head3 Parameters

=over 4

=item * C<$user_lexis_nexis_alert_id> - User lexis nexis alert id

=back

=head3 Returns

=over 4

=item * C<$records> - Json result from Lexis Nexis API

=back

=cut

sub lexis_nexis_results {
    my $user_lexis_nexis_alert_id = shift;

    my $lexis_nexis_api = BOM::Platform::LexisNexisAPI->new(
        update_all => 0,
        count      => 0
    );

    my $auth_token = $lexis_nexis_api->get_jwt_token()->get;

    my $records = $lexis_nexis_api->get_records($auth_token, [$user_lexis_nexis_alert_id])->get;

    return $records;
}

=head2 parse_lexis_nexis_results

    my $matches = parse_lexis_nexis_results($lexis_nexis_results);

This subroutine is used to parse the results from Lexis Nexis API and adds the notes to the matches.

=head3 Parameters

=over 4

=item * C<$lexis_nexis_results> - Json result from Lexis Nexis API

=back

=head3 Returns

=over 4

=item * C<$matches> - Parsed results from Lexis Nexis API

=back

=head3 Example of Note Parsing

=over 4

=item * Event: 'Match Note Added'

=item * Note: 'Created: 2 | 12779040 \n Note ID: 266963  \n Hello World!\n'

=item * Parsed Data:

=over 4

=item * list_reference_number: 12779040

=item * note: 'Hello World!'

=item * note_id: 266963

=item * date: '2024-06-20T12:36:53Z'

=item * user: 'User Name'

=back

=back

=cut

sub parse_lexis_nexis_results {
    my $lexis_nexis_results = shift;
    my $history             = $lexis_nexis_results->[0]->{record_details}->{record_state}->{history};
    my @notes;

    foreach my $hash (@$history) {
        if ($hash->{event} eq "Match Note Added") {
            my $note                    = $hash->{note};
            my ($list_reference_number) = $note         =~ /Created: \d+ \| (\d+)/;
            my ($note_id)               = $note         =~ /Note ID: (\d+)/;
            my ($note_text)             = $note         =~ /Note ID: \d+  \n (.+)/;
            my ($date)                  = $hash->{date} =~ /(\d{4}-\d{2}-\d{2})/;
            my $user                    = $hash->{user};
            my $noteHash                = {
                list_reference_number => $list_reference_number,
                note_id               => $note_id,
                note                  => $note_text,
                date                  => $date,
                user                  => $user,
            };
            push @notes, $noteHash;

            for my $match (@{$lexis_nexis_results->[0]->{watchlist}->{matches}}) {
                if ($match && $match->{entity_details} && $match->{entity_details}->{list_reference_number} eq $list_reference_number) {
                    if ($match->{notes}) {
                        if (ref($match->{notes}) eq 'ARRAY') {
                            push @{$match->{notes}}, $noteHash;
                        } else {
                            $match->{notes} = [$match->{notes}, $noteHash];
                        }
                    } else {
                        $match->{notes} = [$noteHash];
                    }
                }
            }
        }
    }
    my $input_data = _get_input_data_from_record_details($lexis_nexis_results->[0]->{record_details});

    for my $match (@{$lexis_nexis_results->[0]->{watchlist}->{matches}}) {
        $match->{profile_data}->{is_comparing} = 1;
        $match->{profile_data}->{input_data}   = $input_data;

        my $profile_data = _get_profile_data_from_match($match);
        $match->{profile_data}->{profile_data} = $profile_data;

        for my $adverse_media (@{$match->{adverse_medias}}) {
            $adverse_media->{sub_categories} = join(', ', @{$adverse_media->{sub_categories}});
        }

        my @keys_to_delete = qw(
            previous_result_id
            accept_list_id
            best_country_score
            secondary_o_f_a_c_screening_indicator_match
            id
            gateway_o_f_a_c_screening_indicator_match
            check_sum
            match_x_m_l
            entity_details
            d_o_bs
            file
            conflicts
        );

        foreach my $key (@keys_to_delete) {
            delete $match->{$key};
        }
    }

    return $lexis_nexis_results->[0]->{watchlist}->{matches};
}

=head2 _get_profile_data_from_match

    my $profile_data = _get_profile_data_from_match($match);

This subroutine is used to extract profile data from a match.

=head3 Parameters

=over 4

=item * C<$match> - The match data from which profile data will be extracted.

=back

=head3 Returns

=over 4

=item * C<$profile_data> - Extracted profile data.

=back

=cut

sub _get_profile_data_from_match {
    my $match          = shift;
    my $entity_details = $match->{entity_details};

    my $profile_data = {};

    $profile_data->{entity_type} = $entity_details->{entity_type};

    if ($entity_details->{additional_info}) {
        for my $info (@{$entity_details->{additional_info}}) {
            $profile_data->{$info->{type}} = _stringify_values($info->{value});
        }
    }

    my $name        = $entity_details->{name};
    my $name_string = defined $name->{full} ? "$name->{full} ($entity_details->{entity_type})" : "";
    if ($entity_details->{a_k_as}) {
        for my $aka (@{$entity_details->{a_k_as}}) {
            $name_string .= "<br>$aka->{name}->{full} ($aka->{type}, $aka->{category})";
        }
    }
    $profile_data->{name} = $name_string;

    $profile_data->{gender} = $entity_details->{gender};

    if ($entity_details->{i_ds}) {
        my $ids = '';
        for my $id (@{$entity_details->{i_ds}}) {
            $ids .= "$id->{type}: $id->{number}<br>";
        }
        $profile_data->{id_numbers} = $ids;
    }

    if ($entity_details->{addresses}) {
        my $addresses = '';
        for my $address (@{$entity_details->{addresses}}) {
            my $address_string = '';
            for my $key (keys %{$address}) {
                $address_string .= "$key: $address->{$key}<br>";
            }
            $addresses .= "Address ($address->{type}): <br>$address_string<br>";
        }
        $profile_data->{addresses} = $addresses;
    }

    return $profile_data;
}

=head2 _get_input_data_from_record_details

    my $input_data = _get_input_data_from_record_details($record_details);

This subroutine is used to extract input data from record details.

=head3 Parameters

=over 4

=item * C<$record_details> - The record details from which input data will be extracted.

=back

=head3 Returns

=over 4

=item * C<$input_data> - Extracted input data.

=back

=cut

sub _get_input_data_from_record_details {

    my $record_details = shift;

    my $input_data = {};

    if ($record_details->{addresses}) {
        my $addresses = '';
        for my $address (@{$record_details->{addresses}}) {
            for my $key (keys %{$address}) {
                $addresses .= "$key: $address->{$key}<br>";
            }
        }
        $input_data->{addresses} = $addresses;
    }

    if ($record_details->{name}) {
        my $name = '';
        for my $key (keys %{$record_details->{name}}) {
            $name .= "$key: $record_details->{name}->{$key}<br>";
        }
        $input_data->{name} = $name;
    }

    if ($record_details->{additional_info}) {
        for my $info (@{$record_details->{additional_info}}) {
            $input_data->{$info->{type}} = _stringify_values($info->{value});
        }
    }

    if ($record_details->{phones}) {
        my $phones = '';
        for my $phone (@{$record_details->{phones}}) {
            $phones .= "$phone->{type}: $phone->{number}<br>";
        }
        $input_data->{phones} = $phones;
    }

    if ($record_details->{i_ds}) {
        my $ids = '';
        for my $id (@{$record_details->{i_ds}}) {
            $ids .= "$id->{type}: $id->{number}<br>";
        }
        $input_data->{id_numbers} = $ids;
    }

    $input_data->{entity_type} = $record_details->{entity_type};

    return $input_data;
}

=head2 _stringify_values

    my $stringified_values = _stringify_values($values);

This subroutine is used to stringify the values separated by `<br>`.

=head3 Parameters

=over 4

=item * C<$values> - The values to be stringified.

=back

=head3 Returns

=over 4

=item * C<$stringified_values> - Stringified values separated by `<br>`.

=back

=cut

sub _stringify_values {
    my $value = shift;
    if (ref($value) eq 'ARRAY') {
        return join('<br>', @$value);
    } else {
        return $value;
    }
}

=head2 find_risk_screen

    my $rows = find_risk_screen(
        binary_user_id => $binary_user_id,
        client_entity_id => $client_entity_id,
        status => $status
    );

This subroutine is used to get the risk screen results for a given binary user id, client entity id and status.

=head3 Parameters

=over 4

=item * C<$binary_user_id> - Binary user id

=item * C<$client_entity_id> - Client entity id

=item * C<$status> - Status

=back

=head3 Returns

=over 4

=item * C<$rows> - Risk screen results

=back

=cut

sub find_risk_screen {
    my (%args) = @_;

    my @search_fields = qw/binary_user_id client_entity_id status/;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    my $rows = $dbic->run(
        fixup => sub {
            return $_->selectall_arrayref('select * from users.get_risk_screen(?,?,?)', {Slice => {}}, @args{@search_fields});
        });

    return @$rows;
}

1;
