    function createEcoTable(events, id) {

        var table = '<table id="' + id + '" class="economic_event_table">';
        table += '<tr><th>Event Name</th><th>Release Date</th><th>Symbol</th><th>Binary\'s Category, vol_changes are in percent, duration in minutes</th><th width=20%>Change</th><th>functions</th></tr>';
        table += '<tr class="empty"><td>Empty</td></tr>';
        table += '</table>';
        \$('#' + id).html(table);

        if (events.length > 0) {
            for (var i = 0; i < events.length; i++) {
                appendEvent(events[i], id, 0);
            }
        }
    }

    function updateTable(date) {
        if (date) {
            \$.ajax({
                url: ee_upload_url,
                data: {
                    get_event: "1",
                    date: date,
                },
                success: function(data) {
                    var r = JSON.parse(data);
                    createEcoTable(JSON.parse(r.categorized_events), 'scheduled_event_list');
                     createEcoTable(JSON.parse(r.uncategorized_events), 'scheduled_uncategorized_event_list');
                    createEcoTable(JSON.parse(r.deleted_events), 'deleted_event_list');
                }
            });
        }
    }

    function update(id) {
        if (id) {
            var el = \$('tr#' + id);
            var result = el.find('td.update_result');

            result.text('processing ...').show();
            \$.ajax({
                url: ee_upload_url,
                data: {
                    update_event: "1",
                    underlying: el.find('select[name="ul_dropdown"]').val(),
                    vol_change: el.find('input[name="vol_change"]').val(),
                    duration: el.find('input[name="duration"]').val(),
                    decay_factor: el.find('select[name="decay_factor"]').val(),
                    vol_change_before: el.find('input[name="vol_change_before"]').val(),
                    duration_before: el.find('input[name="duration_before"]').val(),
                    decay_factor_before: el.find('select[name="decay_factor_before"]').val(),
                    id: id,
                },
                success: function(data) {
                    var r = \$.parseJSON(data);
                    if (r.error) {
                        result.text(r.error).css('color', 'red');
                    } else {
                        result.text("ok").css('color', 'green');
                        el.find('td#binary_info').html(formatInfo(r));
                    }
                }
            });
        }
    }

    function formatInfoByUL(headers, info, style = '') {
        var text = '';
        var sortedUL = Object.keys(info).sort();
        for (var ulId in sortedUL) {
            text += '<tr'+style+'>';
            var ul = sortedUL[ulId];
            var list = [ul];
            for (var key in headers) {
                if (info[ul][headers[key]]) {
                   var value = info[ul][headers[key]];
                    if(value == "-1000") {
                        value = 'FLAT';
                    }
                    list.push(value);
                } else if (key != 0) {
                    list.push('&nbsp;');
                }
            }
            for (var i = 0; i < list.length; i++) {
                text += "<td>" + list[i] + "</td>";
            }
            text += '</tr>';
        }
        return text;
    }

    function formatInfo(event) {
        var text = '';
        var headers = ['underlying', 'vol_change', 'duration', 'decay_factor', 'vol_change_before', 'duration_before', 'decay_factor_before'];
        if (event.info) {
            text += formatInfoByUL(headers, event.info);
        }
        if (event.custom) {
            var style = ' bgcolor="#00AAAA"';
            text += '<tr'+style+'><td colspan="' + headers.length + '" style="text-align: center;">custom</td></tr>';
            text += formatInfoByUL(headers, event.custom, style);
        }
        if (text != '') {
            var h = '';
            for (var key in headers) {
                h += "<th>" + headers[key] + "</th>";
            }
            text = '<table><tr>' + h + "</tr>" + text + "</table>";

        }
        return text;
    }

    function saveEvent() {
        var el = \$('table#economic_event_form');
        if (el) {
            var result = \$("td.save_result");
            result.text('processing ...');
            var name = el.find('input[name="event_name"]').val();
            var release_date = el.find('input[name="release_date"]').val();
            var symbol = el.find('input[name="symbol"]').val();
            var event_source = el.find('input[name="source"]').val();
            \$.ajax({
                url: ee_upload_url,
                data: {
                    save_event: "1",
                    event_name: name,
                    symbol: symbol,
                    release_date: release_date,
                    source: event_source,
                },
                success: function(data) {
                    var event = \$.parseJSON(data);
                    if (event.error) {
                        result.text(event.error).css('color', 'red');
                    } else {
                        result.text('Event Saved. ID: ' + event.id).css('color', 'green');
                        appendEvent(event, 'scheduled_event_list');
                    }
                }
            });
        }
    }

    function appendEvent(event, table_id, make_green = 1) {
        var table = \$('table#' + table_id);
        table.find('tr.empty').remove();

        var to_append = '<tr id="' + event.id + '">';

        if (event.not_categorized) {
            to_append += '<td>*' + event.event_name + '</td>';
        } else {
            to_append += '<td>' + event.event_name + '</td>';
        }
        to_append += '<td>' + event.release_date + '</td><td>' + event.symbol + '</td><td id="binary_info">';
        to_append += formatInfo(event);
        to_append += '</td><td>';

        to_append += '<table style="border: 0; padding: 0;">';
        to_append += '<tr><td>underlying</td><td><select id="ul_dropdown" name="ul_dropdown"></select></td/tr>';
        to_append += '<tr><td><div class="input_field">vol_change  </td><td><input size="10" type="text" name="vol_change"></div></td/tr>';
        to_append += '<tr><td><div class="input_field">duration    </td><td><input size="10" type="text" name="duration"></div></td/tr>';
        to_append += '<tr><td><div class="input_field">decay_factor</td><td><select id="decay_factor" name="decay_factor"></select></div></td/tr>';
        to_append += '<tr><td><div class="input_field">vol_change_before    </td><td><input size="10" type="text" name="vol_change_before"></div></td/tr>';
        to_append += '<tr><td><div class="input_field">duration_before      </td><td><input size="10" type="text" name="duration_before"></div></td/tr>';
        to_append += '<tr><td><div class="input_field">decay_factor_before  </td><td><select id="decay_factor_before" name="decay_factor_before"></select></div></td/tr>';
        to_append += '</table>';

        to_append += '</td>';

        if (table_id === 'deleted_event_list') {
            to_append += '<td><button onclick="restoreEvent(\'' + event.id + '\')">Restore</button></td> <td style="display:none;" class="update_result"></td>';
        } else {
            to_append += '<td> <button onclick="comparePricePreview(\''+event.id+'\')">Preview</button> </br></br> <button onclick="update( \'' + event.id + '\' )">Update</button> </br></br> <button onclick="deleteEvent( \'' + event.id + '\' )">Delete</button> </td> <td style="display:none;" class="update_result"></td>';
        }
        to_append += '</tr>';
        table.append(to_append);

        var el = \$('tr#' + event.id);
        createDropDown(el.find("select[name='ul_dropdown']"), underlyings);
        createDropDown(el.find("select[name='decay_factor']"), [['default', ''],['FAST', 10],['SLOW', 3],['FLAT', -1000]]);
        createDropDown(el.find("select[name='decay_factor_before']"), [['default', ''],['FAST', 10],['SLOW', 3],['FLAT', -1000]]);

        if (make_green) {
            table.find('tr#' + event.id).css('color', 'green');
        }
    }

    function createDropDown(sel, list) {
        for (var i = 0; i < list.length; i++) {
            var opt = document.createElement('option');
            if(list[i] instanceof Array) {
                opt.innerHTML = list[i][0];
                opt.value = list[i][1];
            } else {
                opt.innerHTML = list[i];
                opt.value = list[i];
            }
            sel.append(opt);
        }
    }

    function deleteEvent(id) {
        if (id) {
            var el = \$('tr#' + id);
            var result = el.find("td.update_result");
            result.text('processing ...').show();
            \$.ajax({
                url: ee_upload_url,
                data: {
                    event_id: id,
                    delete_event: "1"
                },
                success: function(data) {
                    var event = \$.parseJSON(data);
                    if (event.error) {
                        result.text('ERR: ' + event.error).css('color', 'red');
                    } else {
                        \$('tr#' + event.id).remove();
                        appendEvent(event, 'deleted_event_list');
                    }
                }
            });
        }
    }

    function restoreEvent(id) {
        if (id) {
            var el = \$('tr#' + id);
            var result = el.find("td.update_result");
            result.text('processing ...').show();
            \$.ajax({
                url: ee_upload_url,
                data: {
                    event_id: id,
                    restore_event: "1",
                    type: "scheduled"
                },
                success: function(data) {
                    var event = \$.parseJSON(data);
                    if (event.error) {
                        result.text('ERR: ' + event.error).css('color', 'red');
                    } else {
                        appendEvent(event, 'scheduled_event_list');
                        el.remove();
                    }
                }
            });
        }
    }

    function updatePricePreview() {
        var table = \$('table#price_preview_form');
        var symbol = table.find('input[name="symbol"]').val();
        var p_date = table.find('input[name="pricing_date"]').val();
        var p_expiry_option = table.find('select[name="expiry_option"]').val();
        var result = table.find('td.result');
        result.text('processing ...');

        \$.ajax({
            url: pp_upload_url,
            data: {
                update_price_preview: "1",
                symbol: symbol,
                pricing_date: p_date,
                expiry_option: p_expiry_option,
            },
            success: function(data) {
                var event = \$.parseJSON(data);
                if (event.error) {
                    result.text(event.error).css('color', 'red');
                } else {
                    result.text('Price updated for '+symbol).css('color', 'green');
                    createPriceTable(event.headers, event.prices, 'price_preview_original');
                }
            }
        });
    }

    function createPriceTable(headers, prices, id) {
        var el = \$('div#'+id);
        // use back the same style for table
        var table = '<table class="economic_event_table"><tr><th>Symbol</th>';
        for (var i=0; i<headers.length; i++) {
            table += '<th>'+headers[i]+'</th>';
        }
        table += '</tr>';

        Object.keys(prices).forEach(function (key) {
            var data = prices[key];
            table += '<tr><td>'+key+'</td>';
            for (var i=0; i<headers.length; i++) {
                table += '<td>Mid: '+prices[key][headers[i]]["mid_price"]+' Vol: '+prices[key][headers[i]]["vol"]+'</td>';
            }
            table += '</tr>';
        });

        table += '</table>';
        el.html(table);
    }

    function comparePricePreview(id) {
        if (id) {
            var preview_el = \$('table#price_preview_form');
            var el = \$('tr#'+id);
            var result = el.find('td.update_result');
            result.text('processing ...').show();

            \$.ajax({
                url: ee_upload_url,
                data: {
                    compare_price_preview: "1",
                    underlying: el.find('select[name="ul_dropdown"]').val(),
                    vol_change: el.find('input[name="vol_change"]').val(),
                    duration: el.find('input[name="duration"]').val(),
                    decay_factor: el.find('select[name="decay_factor"]').val(),
                    vol_change_before: el.find('input[name="vol_change_before"]').val(),
                    duration_before: el.find('input[name="duration_before"]').val(),
                    decay_factor_before: el.find('select[name="decay_factor_before"]').val(),
                    id: id,
                    compare_symbol: preview_el.find('input[name="symbol"]').val(),
                    compare_date: preview_el.find('input[name="pricing_date"]').val(),
                    compare_expiry_option: preview_el.find('select[name="expiry_option"]').val(),
                },
                success: function(data) {
                    var r = \$.parseJSON(data);
                    if (r.error) {
                        result.text(r.error).css('color', 'red');
                    } else {
                        result.text("ok").css('color', 'green');
                        createPriceTable(r.headers, r.prices, 'price_preview_compare');
                    }
                }
            });
        }
    }

