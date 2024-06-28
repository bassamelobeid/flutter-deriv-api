package BOM::DataView::TableView;

use strict;
use warnings;

use BOM::Backoffice::Request qw(request);
use JSON::MaybeUTF8          qw(encode_json_utf8);

use constant CSS_CHANGE_DATE => '16-05-2024';    # Needed for CSS changes to show due to cache happens at cloundflare side rather than local.

=head2 generate_table

Generate table html from the given data.

=over 4

=item * C<table_id>  - string to help uniquely identify the table for html id.

=item * C<header>  - Exist in data key hash. Used to determine the header of the table. The order of the header will be the order of the array.
=item * C<header_display>  - Exist in data key hash. Optional alternative text to replace the header key. Use hash with header as key and string as display value.
=item * C<editable_columns>  - Exist in data key hash. Optional. Specify witch column(header key) can be editied. Use hash with header as key and string as value for supported data type for html input.
=item * C<unique_column>  - Exist in data key hash. The column key to be used as unique identifier for each row. Only needed if there is a need to target specific row for modification / selection.

=item * C<stylesheets> - Array of stylesheet paths to be included in the html. Can be generate using _generate_stylesheets function.

=item * C<div_container_css_class> - Specify the parent class of css class to apply to its children elements.

=item * C<custom_last_column> - Allow an addtional column to be added to the last column of the table. Use hash with header and td_html as key. Header is the string to display at header while td_html is the td html implementation in string.

=back

Hash ref of the generate table html in string.

=cut

sub generate_table {
    my $args                    = shift;
    my $table_id                = $args->{table_id};
    my @data_headers            = @{($args->{data}->{header} // [])};
    my $data_headers_display    = $args->{data}->{header_display}   // {};
    my $editable_columns        = $args->{data}->{editable_columns} // {};
    my $unique_column           = $args->{data}->{unique_column}    // '';
    my $stylesheets             = $args->{stylesheets}              // [];
    my $div_container_css_class = $args->{div_container_css_class}  // [];
    my $custom_last_column      = $args->{custom_last_column}       // {};

    $div_container_css_class = join(' ', @$div_container_css_class);
    my $headers = join('', map { '<th>' . ($data_headers_display->{$_} // $_) . '</th>' } (@data_headers, $custom_last_column->{header} // ()));
    my $table   = qq{<div class="$div_container_css_class"><table id="$table_id"><thead><tr class="table-header">$headers</tr></thead><tbody>};
    foreach my $row (@{$args->{data}->{data_items}}) {
        my $unique_identifier = $row->{$unique_column};
        $table .= qq{<tr data-row-uid="$unique_identifier">};
        my $is_first_col = 1;
        foreach my $key (@data_headers) {
            my $col_data = $row->{$key} // '';
            if ($is_first_col) {
                $table .= "<th>$col_data</th>";
                $is_first_col = 0;
            } else {
                if ($editable_columns->{$key}) {
                    my $input_data_type = $editable_columns->{$key};
                    $table .= qq{<td class="editable" data-column-key="$key" data-input-data-type="$input_data_type">$col_data</td>};
                } else {
                    $table .= qq{<td data-column-key="$key">$col_data</td>};
                }
            }
        }

        if ($custom_last_column) {
            $table .= $custom_last_column->{td_html} // '';
        }

        $table .= "</tr>";
    }
    $table .= "</tbody></table></div>";
    my $table_generated_html = join('', @$stylesheets) . $table;
    return {table_html => $table_generated_html};
}

=head2 generate_sticky_first_col_header_table

Generate table html that have sticky header and sticky first column.

=over 4

=item * C<args>  - Parameters required by function generate_table function with exception of stylesheets and div_container_css_class.

=back

Hash ref of the generate table html in string.

=cut

sub generate_sticky_first_col_header_table {
    my $args                    = shift;
    my $div_container_css_class = ['sticky-first-col-header-table'];

    $args->{stylesheets}             = _generate_stylesheets(['css/forms/sticky-first-col-header-table.css']);
    $args->{div_container_css_class} = $div_container_css_class;
    return generate_table($args);
}

=head2 generate_sticky_first_col_last_col_with_checkbox_header_table

Generate table html that have sticky header, sticky first column, and a sticky last column consist of checkbox.

=over 4

=item * C<args>  - Parameters required by function generate_table function with exception of stylesheets and div_container_css_class.

=back

Hash ref of the generate table html in string.

=cut

sub generate_sticky_first_col_last_col_with_checkbox_header_table {
    my $args                    = shift;
    my $div_container_css_class = ['sticky_first_col_last_col_with_checkbox_header_table'];

    $args->{stylesheets}             = _generate_stylesheets(['css/forms/sticky_first_col_last_col_with_checkbox_header_table.css']);
    $args->{div_container_css_class} = $div_container_css_class;

    $args->{custom_last_column} = {
        header  => 'sync control',
        td_html => qq{<td data-column-key="sync_control"><input type="checkbox"></td>},
    };
    return generate_table($args);
}

=head2 _generate_stylesheets

Generate array of html link string given css file paths.

=over 4

=item * C<stylesheet_paths>  - Array of string where each item is path of the css file.

=back

Array ref of the generate css link html in string.

=cut

sub _generate_stylesheets {
    my $stylesheet_paths = shift;
    my @stylesheet_html =
        map { '<link rel="stylesheet" type="text/css" href="' . request()->url_for($_) . '?v=' . CSS_CHANGE_DATE . '"/>' } @$stylesheet_paths;
    return \@stylesheet_html;
}

=head2 merge_modified_table_data

Merge modified data with the original. Used for restoring changes made to the table data items.

=over 4

=item * C<table_formated_data>  - Hash ref consist of params that can be used by generate_table. Reference at package BOM::CFDS::DataStruct::PlatformConfigTable

=item * C<modified_table_data>  - Hash ref of modified data. Key is the unique column value and value is hash ref of modified data.

=back

table_formated_data_merged - Return the full table formatted data with the modified data merged.
modified_table_data_merged - Return just the rows of modified data that is merged with missing column value from original data.

=cut

sub merge_modified_table_data {
    my $args                = shift;
    my $table_formated_data = $args->{table_formated_data};
    my $modified_table_data = $args->{modified_table_data};
    my $unique_column       = $table_formated_data->{unique_column} // '';

    my @merged_data;
    foreach my $row (@{$table_formated_data->{data_items}}) {
        if (exists $modified_table_data->{$row->{$unique_column}}) {
            foreach my $key (keys %{$modified_table_data->{$row->{$unique_column}}}) {
                $row->{$key} = $modified_table_data->{$row->{$unique_column}}->{$key};
            }
            push @merged_data, $row;
        }
    }

    return {
        table_formated_data_merged => $table_formated_data,
        modified_table_data_merged => \@merged_data
    };
}

=head2 generate_table_global_search_input_box

Generate html and script of input box for global search of table content.

=over 4

=item * C<table_id>  - The html table id that the search input box will be used to search.

=item * C<header>  - Array of string to target which column of the table to support search function.

=item * C<header_display>  - Exist in data key hash. Optional alternative text to replace the header key. Use hash with header as key and string as display value.

=back

search_html - Return the html of the input box.
script - Return the script to handle the search functionality of the input box.

=cut

sub generate_table_global_search_input_box {
    my $args                 = shift;
    my $table_element_id     = $args->{table_id};
    my $input_element_id     = $table_element_id . '_input';
    my $dropdown_id          = $table_element_id . '_dropdown';
    my $function_name        = $table_element_id . 'GlobalSearchFunction';
    my @headers              = @{$args->{header} // []};
    my $data_headers_display = $args->{header_display} // {};
    my $options              = join '',
        map { my $header_selected = ($data_headers_display->{$_} // $_); "<option value='$header_selected'>$header_selected</option>" } @headers;
    my $input_box = <<HTML;
    <select id="$dropdown_id">
        <option value="all">All</option>
        $options
    </select>
    <input
        type="text"
        id=$input_element_id
        onkeyup="$function_name()"
        placeholder="Search table content"
        title="This search the table below globally regardless of column">
HTML

    my $script = <<JAVASCRIPT;
    <script>
        document.querySelector('#$dropdown_id').addEventListener("change", function() {
            $function_name();
        });

        function $function_name() {
                const trs = document.querySelectorAll('#$table_element_id tr:not(.table-header)');
                const filter = document.querySelector('#$input_element_id').value;
                const column = document.querySelector('#$dropdown_id').value;
                const regex = new RegExp(filter, 'i');
                const headers = Array.from(document.querySelector('#$table_element_id .table-header').children).map(td => td.innerHTML);
                const columnIndex = headers.indexOf(column);
                const isFoundInTds = td => {
                    const inputElement = td.querySelector('input');
                    const inputValue = inputElement ? inputElement.value : '';
                    const cellValue = td.innerHTML;
                    const testValue = column === 'all' ? regex.test(cellValue) || regex.test(inputValue) : td.cellIndex === columnIndex && (regex.test(cellValue) || regex.test(inputValue));
                    return testValue;
                };
                const isFound = childrenArr => childrenArr.some(isFoundInTds);
                const setTrStyleDisplay = ({ style, children }) => {
                    style.display = isFound([
                    ...children // <-- All columns
                    ]) ? '' : 'none'
                };
                trs.forEach(setTrStyleDisplay);
            }
    </script>
JAVASCRIPT

    return {
        search_html => $input_box,
        script      => $script
    };

}

=head2 generate_table_edit_save_button

Generate html and script of Edit/Save button for processing of modified table content.

=over 4

=item * C<table_id>  - The html table id that the button will target.

=item * C<redirect_url>  - Which url to redirect to after the save button is clicked.

=item * C<action_identifier>  - Uniquely identifiable string to help distinguish the purpose of the action.

=item * C<form_input_ref_name>  - The form input submission name reference. Used for targeting params to read in destination url of redirect_url.

=item * C<resume_modified_data>  - Hash ref of modified data that is used to restore the javascript object that keep track of modified data.

=item * C<additional_data>  - Hash ref to any key value need to be passed to redirect_url page for further uses.

=back

button_html - Return the html of the button.
script - Return the script to handle the procssing logic of the button_html.

=cut

sub generate_table_edit_save_button {
    my $args                = shift;
    my $table_element_id    = $args->{table_id};
    my $edit_button_id      = $table_element_id . 'EditButton';
    my $edit_function_name  = $table_element_id . 'EditFunction';
    my $save_function_name  = $table_element_id . 'SaveFunction';
    my $table_data_hash     = $table_element_id . 'DataHash';
    my $resume_data_var_ref = $table_element_id . 'ResumeModifiedData';
    my $redirect_url        = $args->{redirect_url};
    my $action_identifier   = $args->{action_identifier};
    my $form_input_ref_name = $args->{form_input_ref_name};
    my $additional_data     = $args->{additional_data} // {};
    $additional_data = encode_json_utf8($additional_data);
    my $resume_modified_data = $args->{resume_modified_data} // {};
    $resume_modified_data = encode_json_utf8($resume_modified_data);

    my $edit_button = <<HTML;
    <button id="$edit_button_id" class="button" onclick="$edit_function_name()">Edit</button>
HTML

    my $script = <<JAVASCRIPT;
        <script>
            let $table_data_hash = {};
            let $resume_data_var_ref = JSON.parse('$resume_modified_data');
            if (Object.keys($resume_data_var_ref).length !== 0) {
                $table_data_hash = $resume_data_var_ref;
                $edit_function_name();
            }

            function $edit_function_name() {
                const tdsEditable = document.querySelectorAll('#$table_element_id td.editable');
                tdsEditable.forEach(td => {
                    let originalText = td.innerText;
                    let dataType = td.getAttribute('data-input-data-type');
                    td.innerHTML = '<input value="' + originalText + '" />';

                    let rowUid = td.parentElement.getAttribute('data-row-uid');
                    let columnKey = td.getAttribute('data-column-key');
                    let input = td.querySelector('input');
                    input.type = dataType;
                    input.addEventListener('input', function() {
                        let value = this.value;

                        if (!$table_data_hash\[rowUid]) {
                            $table_data_hash\[rowUid] = {};
                        }

                        $table_data_hash\[rowUid][columnKey] = value;
                    });

                });

                document.getElementById("$edit_button_id").innerText = "Save";
                document.getElementById("$edit_button_id").setAttribute("onclick", "$save_function_name()");
            }

            function $save_function_name() {
                const tdsEditable = document.querySelectorAll('#$table_element_id td.editable');
                tdsEditable.forEach(td => {
                    let input = td.querySelector('input');
                    if (input) {
                        td.innerText = input.value;
                    }
                });
                document.getElementById("$edit_button_id").innerText = "Edit";
                document.getElementById("$edit_button_id").setAttribute("onclick", "$edit_function_name()");

                // Create and submit form
                if (Object.keys($table_data_hash).length !== 0) {
                    let additional_data = JSON.parse('$additional_data');
                    let form_return_data = {
                        action_identifier: '$action_identifier',
                        modified_table_data: $table_data_hash,
                        additional_data: additional_data,
                    };
                    let form = document.createElement('form');
                    form.method = 'POST';
                    form.action = '$redirect_url';
                    let hiddenField = document.createElement('input');
                    hiddenField.type = 'hidden';
                    hiddenField.name = '$form_input_ref_name';
                    hiddenField.value = JSON.stringify(form_return_data);
                    form.appendChild(hiddenField);
                    document.body.appendChild(form);
                    form.submit();
                }
            }
    </script>
JAVASCRIPT

    return {
        button_html => $edit_button,
        script      => $script
    };

}

=head2 generate_table_confirm_checkbox_button

Generate html and script of Confirm button for processing of selected table content. Intended for generated table with checkbox.

=over 4

=item * C<table_id>  - The html table id that the button will target.

=item * C<redirect_url>  - Which url to redirect to after the save button is clicked.

=item * C<action_identifier>  - Uniquely identifiable string to help distinguish the purpose of the action.

=item * C<form_input_ref_name>  - The form input submission name reference. Used for targeting params to read in destination url of redirect_url.

=item * C<resume_modified_data>  - Hash ref of modified data that is used to restore the javascript object that keep track of modified data.

=item * C<additional_data>  - Hash ref to any key value need to be passed to redirect_url page for further uses.

=back

button_html - Return the html of the button.
script - Return the script to handle the procssing logic of the button_html.

=cut

sub generate_table_confirm_checkbox_button {
    my $args                           = shift;
    my $table_element_id               = $args->{table_id};
    my $confirm_checkbox_button_id     = $table_element_id . 'ConfirmCheckboxButton';
    my $confirm_checkbox_function_name = $table_element_id . 'ConfirmCheckboxFunction';
    my $table_data_hash                = $table_element_id . 'CheckboxDataHash';
    my $resume_data_var_ref            = $table_element_id . 'ResumeCheckboxModifiedData';
    my $redirect_url                   = $args->{redirect_url};
    my $action_identifier              = $args->{action_identifier};
    my $form_input_ref_name            = $args->{form_input_ref_name};
    my $additional_data                = $args->{additional_data} // {};
    $additional_data = encode_json_utf8($additional_data);
    my $resume_modified_data = $args->{resume_modified_data} // {};
    $resume_modified_data = encode_json_utf8($resume_modified_data);

    my $confirm_button = <<HTML;
    <button id="$confirm_checkbox_button_id" class="button" onclick="$confirm_checkbox_function_name()">Confirm</button>
HTML

    my $script = <<JAVASCRIPT;
        <script>
            let $table_data_hash = {};
            let $resume_data_var_ref = JSON.parse('$resume_modified_data');
            if (Object.keys($resume_data_var_ref).length !== 0) {
                $table_data_hash = $resume_data_var_ref;
                let tableRows = document.querySelectorAll('#$table_element_id tbody tr');

                tableRows.forEach(row => {
                    let rowUid = row.getAttribute('data-row-uid');
                    if ($table_data_hash.hasOwnProperty(rowUid)) {
                        let checkbox = row.querySelector('td input[type="checkbox"]');
                        if (checkbox) {
                            checkbox.click();
                        }
                    }
                });
            }

            document.addEventListener("DOMContentLoaded", function() {
                const tdsInputWithCheckbox = document.querySelectorAll('#$table_element_id td input[type="checkbox"]');
                tdsInputWithCheckbox.forEach(checkbox => {
                    let rowUid = checkbox.parentElement.parentElement.getAttribute('data-row-uid');
                    let columnKey = checkbox.parentElement.getAttribute('data-column-key');
                    checkbox.addEventListener('change', function() {
                        if (this.checked) {
                            if (!$table_data_hash\[rowUid]) {
                                $table_data_hash\[rowUid] = {};
                            }
                            $table_data_hash\[rowUid][columnKey] = 'yes';
                        } else {
                            if ($table_data_hash\[rowUid]) {
                                delete $table_data_hash\[rowUid];
                            }
                        }
                    });
                });
            });

            function $confirm_checkbox_function_name() {
                if (Object.keys($table_data_hash).length !== 0) {
                    let additional_data = JSON.parse('$additional_data');
                    let form_return_data = {
                        action_identifier: '$action_identifier',
                        modified_table_data: $table_data_hash,
                        additional_data: additional_data,
                    };
                    let form = document.createElement('form');
                    form.method = 'POST';
                    form.action = '$redirect_url';
                    let hiddenField = document.createElement('input');
                    hiddenField.type = 'hidden';
                    hiddenField.name = '$form_input_ref_name';
                    hiddenField.value = JSON.stringify(form_return_data);
                    form.appendChild(hiddenField);
                    document.body.appendChild(form);
                    form.submit();
                }
            }
    </script>
JAVASCRIPT

    return {
        button_html => $confirm_button,
        script      => $script
    };

}

return 1;
