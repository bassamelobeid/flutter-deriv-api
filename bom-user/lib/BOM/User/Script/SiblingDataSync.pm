package BOM::User::Script::SiblingDataSync;

=head1 NAME

BOM::User::Script::SiblingDataSync - Module for synchronizing data between MF and CR accounts

=head1 SYNOPSIS

This module provides functionality to synchronize data of immutable fields limited to (account_opening_reason, tax_identification_number, tax_residence) between MF and CR accounts. You can use this module by calling the run method as shown below:

    BOM::User::Script::SiblingDataSync->run({
        file_path  => $file_path, 
        dry_run    => $dry_run, 
        fields_ref => $fields_ref,
        log_level  => $log_level,
    });


# Expected CSV format
    binary_user_id  mf_login_ids    mf_tax_country  cr_tax_country  cr_login_ids
    6282093         MF63849         South Africa    Zimbabwe        CR3038216,CR2693588,CR4070601,CR4204637,CR841144,CR890354

# Result CSV format containing the report of the sync
    mf_login_id     cr_login_id     updated_field               old_value       new_value           error
    MF000001        CR000001        tax_identification_number   111-111-111     222-222-222    
    MF000001        CR000002        account_opening_reason      Speculative     Income Earning    
    MF000004        CR000001                                                                        Invalid loginid: CR000001

The CSV will be exported to /tmp with the name of sync_output_<timestamp>.csv

=head1 DESCRIPTION

This module is used by the `sync_siblings_data.pl` script. Meant to provide a testable
collection of subroutines.


=cut

use strict;
use warnings;
no indirect;
use Log::Any     qw($log);
use Text::CSV_XS qw( csv );
use Syntax::Keyword::Try;
use Time::Piece;
use Array::Utils;
use List::Util;

use BOM::User::Client;

use constant ALLOWED_FIELDS => qw(account_opening_reason tax_identification_number tax_residence);

=head2 run

Takes a hashref of parameters as:

=over

=item * C<file_path> (mandatory) - The path to the CSV file containing the binary_user_id, source mf_login_ids, and target cr_login_ids.

=item * C<dry_run> (optional) - If set to 1, the script will perform a dry run and print the details of 5 clients with the fields from both MF and CR accounts.

=item * C<fields_ref> (optional) - An array reference containing the fields that must be copied from the MF account to CR accounts. If not provided, the default fields will be used.

=back

Returns a C<string> representing the path to the CSV report that is created.

=cut

sub run {

    my ($self, $args) = @_;

    # Validate arguments
    my $file_path  = $args->{file_path} or die "file_path is mandatory";
    my $fields_ref = $args->{fields_ref} // [ALLOWED_FIELDS];
    my $dry_run    = $args->{dry_run}    // 0;

    my $file_content_ref = parse_file($file_path);

    die("Empty or invalid CSV file") unless $file_content_ref;

    my $report = copy_data_for_all_clients($file_content_ref, $fields_ref, $dry_run);
    return export_to_csv($report);
}

=head2 validate_fields

Checks if all the input fields are among the allowed fields and return 1 if true

=over

=item *  C<fields_to_validate> - Fields that have to be validated against the allowed fields

=back

Returns a C<integer> or C<undef> with the following meaning:
- 1 if fields are valid
- undef if fields are invalid

=cut

sub validate_fields {
    my $ref_fields_to_validate = shift;

    my @fields_to_validate = $ref_fields_to_validate->@*;

    return undef unless scalar @fields_to_validate;

    # Allowed values
    my @allowed_fields = ALLOWED_FIELDS;

    # Filter the fields_to_validate to only contain allowed values
    my @filtered_fields = Array::Utils::intersect(@fields_to_validate, @allowed_fields);

    return scalar(@filtered_fields) == scalar(@fields_to_validate) ? 1 : undef;
}

=head2 parse_file

Parse the file on the given path and return its contents as an array of hashrefs

Input: CSV file path
Returns arrayref of hashrefs of data in the given CSV file

=over

=item C<file_path> - CSV file path

=back

Returns a C<arrayref> of the file that is parsed. e.g
[
    {
        column1 => 'value1',
        column2 => 'value2',
        column3 => 'value3',
    },
    {
        column1 => 'value4',
        column2 => 'value5',
        column3 => 'value6',
    },
    {
        column1 => 'value7',
        column2 => 'value8',
        column3 => 'value9',
    },
]

=cut

sub parse_file {
    my $file_path = shift;

    my $aoh = csv(
        in      => $file_path,
        headers => "auto"
    );

    return $aoh;
}

=head2 validate_content

Validates the content of an array of hashrefs. Returns 1 if all hashrefs contain the required keys, 0 otherwise.

=over

=item * C<$array_ref> - Reference to an array of hashrefs to be validated.

=back

Returns a C<integer> with the following meaning:
- 1 if content is valid and contains the required keys
- 0 if content is invalid and does not contain the required keys

=cut

sub validate_content {
    my $array_ref = shift;
    my @keys      = qw(binary_user_id mf_login_ids mf_tax_country cr_tax_country cr_login_ids);

    foreach my $hash_ref (@$array_ref) {
        return 0 unless (ref($hash_ref) eq 'HASH' && List::Util::all { defined } @$hash_ref{@keys});
    }

    return 1;
}

=head2 copy_data_to_siblings

Back populate data to client siblings if new data is added. Returns array of hashrefs to error mapper and updated fields mapper

=over

=item C<cur_client> - current client object.

=item C<ref_cr_login_ids> - Referral of an array of CR login ids.

=item C<ref_fields_to_populate> - Referral of an array of fields that have to be copied to the siblings.

=item C<dry_run_l> - Integer to dictate if code has to be ran in dry run mode.

=back

Returns a C<arrayref> containing two hashrefs. e.g
[
    {
      sibling_login_id1 => [
          { field_name => 'field1', old_value => 'old_value1', new_value => 'new_value1' },
          { field_name => 'field2', old_value => 'old_value2', new_value => 'new_value2' },
      ],
      sibling_login_id2 => [
          { field_name => 'field3', old_value => 'old_value3', new_value => 'new_value3' },
      ],
    },
    {
      sibling_login_id1 => "Error message for sibling 1",
      sibling_login_id2 => "Error message for sibling 2",
      sibling_login_id3 => "Error message for sibling 3",
    }
]

=cut

sub copy_data_to_siblings {
    my ($client, $ref_cr_login_ids, $ref_fields_to_populate, $dry_run_l) = @_;

    # Initializing mappers to use for generating the report where each key is the sibling loginid

    my %sibling_login_id_updated_fields_mapper;

    # Example structure
    # {
    #   sibling_login_id1 => [
    #       { field_name => 'field1', old_value => 'old_value1', new_value => 'new_value1' },
    #       { field_name => 'field2', old_value => 'old_value2', new_value => 'new_value2' },
    #       # Additional field updates for sibling_login_id1
    #   ],
    #   sibling_login_id2 => [
    #       { field_name => 'field3', old_value => 'old_value3', new_value => 'new_value3' },
    #       # Additional field updates for sibling_login_id2
    #   ],
    #   # Additional sibling login IDs and their field updates
    # }

    my %sibling_login_id_error_mapper;

    # Example structure:
    # {
    #   sibling_login_id1 => "Error message for sibling 1",
    #   sibling_login_id2 => "Error message for sibling 2",
    #   sibling_login_id3 => "Error message for sibling 3",
    #   # Additional sibling login IDs and their corresponding error messages
    # }

    printf("Updating for Client: %s \n", $client->loginid) if $dry_run_l;

    die "No user object found for client: $client->loginid \n" unless $client->user;
    for my $sibling_cr_id ($ref_cr_login_ids->@*) {
        try {
            my $sibling = BOM::User::Client->new({loginid => $sibling_cr_id});

            die "Undefined sibling object fetched" unless defined $sibling;

            next if $sibling->is_virtual;
            next if $sibling->loginid eq $client->loginid;
            die "Given CR loginID: $sibling_cr_id does not belong to given MF loginID: $client->loginid \n"
                unless $sibling->binary_user_id eq $client->binary_user_id;

            # Initializing empty array to populate for the updated fields
            $sibling_login_id_updated_fields_mapper{$sibling->loginid} = [];

            for my $field ($ref_fields_to_populate->@*) {
                my $current_value = $client->$field  // '';
                my $sibling_value = $sibling->$field // '';
                if ($current_value ne $sibling_value && $current_value ne '') {
                    $sibling->$field($current_value);
                    my %updated_fields = (
                        field_name => $field,
                        old_value  => $sibling_value,
                        new_value  => $current_value
                    );
                    # Updating the mapper for the fields that are updated
                    push @{$sibling_login_id_updated_fields_mapper{$sibling->loginid}}, \%updated_fields;
                }
            }

            $sibling->save() unless $dry_run_l;

            my @fields_updated = map { $_->{field_name} } @{$sibling_login_id_updated_fields_mapper{$sibling->loginid}};

            if (scalar(@fields_updated)) {
                $log->infof("Fields updated of Sibling: %s of Client: %s", $sibling->loginid, $client->loginid);
                printf("Field(s): '%s' of sibling: %s of client: %s\n", join(', ', @fields_updated), $sibling->loginid, $client->loginid)
                    if $dry_run_l;

            } else {
                $log->infof("No fields updated for sibling: %s of client: %s", $sibling->loginid, $client->loginid);
                delete $sibling_login_id_updated_fields_mapper{$sibling->loginid};
            }

        } catch ($e) {

            chomp($e);    # Removing trailing \n to easily write to csv

            # Updating the error mapper for the sibling login id
            @sibling_login_id_error_mapper{$sibling_cr_id} = $e;

            $log->errorf("Error caught when back-populating data back to siblings: %s", $e);

            # Deleting the empty array assigned for sibling login id in the $sibling_login_id_updated_fields_mapper
            delete $sibling_login_id_updated_fields_mapper{$sibling_cr_id};
        }

    }
    return (\%sibling_login_id_error_mapper, \%sibling_login_id_updated_fields_mapper);
}

=head2 copy_data_for_all_clients

Back populate data to for all client objects given.

=over

=item * C<file_content_ref> - Reference to an array of hashes containing the client login IDs and their corresponding data to be copied to siblings.

=item * C<ref_fields_to_populate> - Reference of an array of fields that have to be copied to the siblings.

=item * C<dry_run_l> - Integer to dictate if code has to be ran in dry run mode and gives information of at most five clients.

=back

Returns a C<arrayref> of the file that is parsed. e.g
[
    {
        mf_login_id   => 'MF000001',
        cr_login_id   => 'CR000001',
        updated_field => 'tax_identification_number',
        old_value     => '111-111-111',
        new_value     => '222-222-222',
        error         => '',
    },
    {
        mf_login_id   => 'MF000001',
        cr_login_id   => 'CR000002',
        updated_field => 'account_opening_reason',
        old_value     => 'Speculative',
        new_value     => 'Income Earning',
        error         => '',
    },
    {
        mf_login_id   => 'MF000004',
        cr_login_id   => 'CR000001',
        updated_field => '',
        old_value     => '',
        new_value     => '',
        error         => 'Invalid loginid: CR000001',
    },
]

=cut

sub copy_data_for_all_clients {

    my ($file_content_ref, $ref_fields_to_populate, $dry_run_l) = @_;

    # Validating given fields
    die("One or more given fields are invalid. Allowed fields are: @{[ALLOWED_FIELDS]}") unless validate_fields($ref_fields_to_populate);

    die("Invalid file content") unless validate_content($file_content_ref);

    # Initializing counter to stop showing information after showing information of 5 clients.
    my $dry_run_counter = 0;

    my @report;
    for my $row ($file_content_ref->@*) {
        my $client_mf_id = $row->{mf_login_ids};
        my $client;
        try {
            $client = BOM::User::Client->new({loginid => $client_mf_id});
            if (not defined $client) {
                die "Undefined client object fetched";
            }
        } catch ($e) {
            chomp($e);
            $log->errorf("Error caught while fetching client with loginid: %s. Continuing to next client", $client_mf_id);
            push @report,
                {
                mf_login_id   => $client_mf_id,
                cr_login_id   => '',
                error         => $e,
                updated_field => '',
                old_value     => '',
                new_value     => ''
                };

            next;
        }

        # Getting cr login ids against the mf client
        my @cr_login_ids = split(',', $row->{cr_login_ids});

        my @result;

        if ($dry_run_counter < 5) {
            try {
                @result = copy_data_to_siblings($client, \@cr_login_ids, $ref_fields_to_populate, $dry_run_l);
            } catch ($e) {
                $log->error($e);
                chomp($e);
                push @report,
                    {
                    mf_login_id   => $client_mf_id,
                    cr_login_id   => '',
                    error         => $e,
                    updated_field => '',
                    old_value     => '',
                    new_value     => ''
                    };

            }
        }

        if ($dry_run_l) {
            print "\n";
            $dry_run_counter += 1;
        }

        die "Empty report made" unless scalar(@result);

        # Fetching mappers to generate csv report
        my ($sibling_login_id_error_mapper, $sibling_login_id_updated_fields_mapper) = @result;

        for my $key (keys %$sibling_login_id_updated_fields_mapper) {

            # Getting array of hashrefs of updated fields
            # { field_name => 'field', old_value => 'old_value', new_value => 'new_value' }

            my @updated_fields = @{$sibling_login_id_updated_fields_mapper->{$key}};
            for my $updated_field (@updated_fields) {

                push @report,
                    {
                    mf_login_id   => $client_mf_id,
                    cr_login_id   => $key,
                    error         => '',
                    updated_field => $updated_field->{field_name},
                    old_value     => $updated_field->{old_value},
                    new_value     => $updated_field->{new_value}};

            }

        }

        for my $key (keys %$sibling_login_id_error_mapper) {
            push @report,
                {
                mf_login_id   => $client_mf_id,
                error         => $sibling_login_id_error_mapper->{$key},
                cr_login_id   => $key,
                updated_field => '',
                old_value     => '',
                new_value     => ''
                };
        }

    }

    return [@report];

}

=head2 export_to_csv

Export an array reference to a CSV file with headers. Returns the name of the output file.

=over

=item * C<$array_ref> - Reference to an array of hashrefs containing data to be exported.

=back

Returns a C<string> representing the path to the CSV report that is created.

=cut

sub export_to_csv {
    my $timestamp   = localtime->epoch;
    my $output_file = "/tmp/sync_output_$timestamp.csv";
    my $array_ref   = shift;

    my @headers = qw(mf_login_id cr_login_id updated_field old_value new_value error);

    csv(
        headers => \@headers,
        in      => $array_ref,
        out     => $output_file
    );

    return $output_file;
}

1;
