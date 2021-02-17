    function createEcoTable(events, id) {

        var table = '<table id="' + id + '" class="economic_event_table border">';
        table += '<thead><tr><th>Event Name</th><th>Release Date</th><th>Symeconomic_event_tablebol</th><th>Binary\'s Category, vol_changes are in percent, duration in minutes</th><th width=20%>Change</th><th>functions</th></tr><thead>';
        table += '<tbody><tr class="empty"><td>Empty</td></tr>';
        table += '</tbody></table>';
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
                        result.text(r.error).css('color', 'var(--color-red)');
                    } else {
                        result.text("ok").css('color', 'var(--color-green-2)');
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
                    if(headers[key].includes('vol_change')){
                        value *= 100;
                        value = Math.round(value);
                    }
                    if(headers[key].includes('duration')){
                        value /= 60;
                        value = Math.round(value);
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
            var style = ' class="bg-highlight"';
            text += '<tr'+style+'><td colspan="' + headers.length + '" style="text-align: center;">custom</td></tr>';
            text += formatInfoByUL(headers, event.custom, style);
        }
        if (text != '') {
            var h = '';
            for (var key in headers) {
                h += "<th>" + headers[key] + "</th>";
            }
            text = '<table><thead><tr>' + h + "</tr></thead><tbody>" + text + "</tbody></table>";

        }
        return text;
    }

    function saveEvent() {
        var el = \$('table#economic_event_form');
        if (el) {
            var result = \$("td.save_result");
            result.text('processing ...').css('color', 'black');
            var name = el.find('input[name="event_name"]').val();
            var release_date = el.find('input[name="release_date"]').val();
            var impact = el.find('input[name="impact"]').val();
            var date_re = /^(\d{10}|\d{4}-\d{2}-\d{2}( \d{2}:\d{2}:\d{2})?)\$/;
            if(!date_re.test(release_date)){
                result.text("Invaild DateTime entered").css('color', 'var(--color-red)');
                return true;
            }
            var symbol = el.find('input[name="symbol"]').val();
            var event_source = el.find('input[name="source"]').val();
            \$.ajax({
                url: ee_upload_url,
                data: {
                    save_event: "1",
                    event_name: name,
                    symbol: symbol,
                    impact: impact,
                    release_date: release_date,
                    source: event_source,
                },
                success: function(data) {
                    var event = \$.parseJSON(data);
                    if (event.error) {
                        result.text(event.error).css('color', 'var(--color-red)');
                    } else {
                        result.text('Event Saved. ID: ' + event.id).css('color', 'var(--color-green-2)');
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

        to_append += '<table>';
        to_append += '<tr><td>underlying</td><td><select id="ul_dropdown" name="ul_dropdown"></select></td/tr>';
        to_append += '<tr><td><div class="input_field">vol_change  </td><td><input size="10" type="text" name="vol_change" data-lpignore="true" /></div></td/tr>';
        to_append += '<tr><td><div class="input_field">duration    </td><td><input size="10" type="text" name="duration" data-lpignore="true" /></div></td/tr>';
        to_append += '<tr><td><div class="input_field">decay_factor</td><td><select id="decay_factor" name="decay_factor"></select></div></td/tr>';
        to_append += '<tr><td><div class="input_field">vol_change_before    </td><td><input size="10" type="text" name="vol_change_before" data-lpignore="true" /></div></td/tr>';
        to_append += '<tr><td><div class="input_field">duration_before      </td><td><input size="10" type="text" name="duration_before" data-lpignore="true" /></div></td/tr>';
        to_append += '<tr><td><div class="input_field">decay_factor_before  </td><td><select id="decay_factor_before" name="decay_factor_before"></select></div></td/tr>';
        to_append += '</table>';

        to_append += '</td>';

        if (table_id === 'deleted_event_list') {
            to_append += '<td><button onclick="restoreEvent(\'' + event.id + '\')" class="btn btn--red">Restore</button></td> <td style="display:none;" class="update_result"></td>';
        } else {
            to_append += '<td> <button onclick="comparePricePreview(\''+event.id+'\')" class="btn btn--primary">Preview</button> </br></br> <button onclick="update( \'' + event.id + '\' )" class="btn btn--primary">Update</button> </br></br> <button onclick="deleteEvent( \'' + event.id + '\' )" class="btn btn--secondary">Delete</button> </td> <td style="display:none;" class="update_result"></td>';
        }
        to_append += '</tr>';
        table.append(to_append);

        var el = \$('tr#' + event.id);
        createDropDown(el.find("select[name='ul_dropdown']"), underlyings);
        createDropDown(el.find("select[name='decay_factor']"), [['default', ''],['FAST', 10],['SLOW', 3],['FLAT', -1000]]);
        createDropDown(el.find("select[name='decay_factor_before']"), [['default', ''],['FAST', 10],['SLOW', 3],['FLAT', -1000]]);

        if (make_green) {
            table.find('tr#' + event.id).css('color', 'var(--color-green-2)');
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
                        result.text('ERR: ' + event.error).css('color', 'var(--color-red)');
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
                        result.text('ERR: ' + event.error).css('color', 'var(--color-red)');
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
                    result.text(event.error).css('color', 'var(--color-red)');
                } else {
                    result.text('Price updated for '+symbol).css('color', 'var(--color-green-2)');
                    createPriceTable(event.headers, event.prices, 'price_preview_original');
                }
            }
        });
    }

    function createPriceTable(headers, prices, id) {
        var el = \$('div#'+id);
        // use back the same style for table
        var table = '<table class="economic_event_table border hover"><thead><tr><th>Symbol</th>';
        for (var i=0; i<headers.length; i++) {
            table += '<th>'+headers[i]+'</th>';
        }
        table += '</tr></thead><tbody>';

        Object.keys(prices).forEach(function (key) {
            var data = prices[key];
            table += '<tr><td>'+key+'</td>';
            for (var i=0; i<headers.length; i++) {
                table += '<td>Mid: '+prices[key][headers[i]]["mid_price"]+' Vol: '+prices[key][headers[i]]["vol"]+'</td>';
            }
            table += '</tr>';
        });

        table += '</tbody></table>';
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
                        result.text(r.error).css('color', 'var(--color-red)');
                    } else {
                        result.text("ok").css('color', 'var(--color-green-2)');
                        createPriceTable(r.headers, r.prices, 'price_preview_compare');
                    }
                }
            });
        }
    }

    function updateEconomicEventPricePreview() {
        var table = \$('table#economic_event_price_preview_form');
        var date = table.find('select[name="date"]').val();
        var underlying_symbol = table.find('select[name="underlying_symbol"]').val();
        var event_timeframe = table.find('select[name="event_timeframe"]').val();
        var event_type = table.find('select[name="event_type"]').val();
        var event_name = table.find('select[name="event_name"]').val();
        var result = table.find('td.result');
        result.text('processing ...');

        \$.ajax({
            url: eco_preview_upload_url,
            data: {
                update_economic_event_price_preview: "1",
                date : date,
                underlying_symbol: underlying_symbol,
                event_timeframe: event_timeframe,
                event_type: event_type,
                event_name: event_name
            },
            success: function(data) {
                var event = \$.parseJSON(data);
                if (event.error) {
                    result.text(event.error).css('color', 'var(--color-red)');
                } else {
                    if(event.headers == undefined){
                        result.text('Event not found').css('color', 'var(--color-red)');
                    }else{
                        result.text('Price updated').css('color', 'var(--color-green-2)');
                        createEconomicEventPriceTable(event.headers, event.prices, 'economic_event_price_preview_original');
                        createEconomicEventInfo(event.news_info, 'economic_event_info');

                    }
                }
            }
        });
    }

    function createEconomicEventPriceTable(headers, prices, id) {
        var el = \$('div#'+id);

        var table = '<table class="economic_event_table border hover"><tr><th>Start Time / Expiry Time</th>';
        for (var i=0; i<headers.length; i++) {
            table += '<th>'+headers[i]+'</th>';
        }
        table += '</tr>';

        Object.keys(prices).sort().forEach(function (key) {
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

   function createEconomicEventInfo(news_info, id) {

        var el = \$('div#'+id);
        var news_info_header = [['Symbol','symbol'],['Event Name','event_name'],['Underlying Symbol', 'underlying_symbol'],['Current Spot','current_spot'],['Release Date','release_date'],['Duration','duration'],['Vol Change','vol_change'],['Decay Factor','decay_factor'],['Vol Change Before','vol_change_before'],['Decay Factor Before','decay_factor_before']];
        var table = '<p><b>News Info</b></p>';
        table += '<table class="economic_event_table border hover">';
        table += '<thead><tr>';
        for (var i=0; i<news_info_header.length; i++) {
            table += '<th> '+news_info_header[i][0]+' </th>';
        }
        table += '</tr></thead>';
        table += '<tbody><tr>';
        for (var i=0; i<news_info_header.length; i++) {
            if(news_info[news_info_header[i][1]] == undefined){
                table += '<td> - </td>';
            }else{
                table += '<td> '+news_info[news_info_header[i][1]]+' </td>';
            }
        }
        table += '</tr>';
        table += '</tbody></table>';
        el.html(table);
    }


    function createEconomicEventForm(weekly_news, id) {

       var el = \$('div#'+id);
       var table = '<table id="' + id + '" class="economic_event_table border hover">';

       table += '<tr><td>Date</td><td><select id="date" name="date"></select></td/tr>';
       table += '<tr><td>Underlying Symbol</td><td><select id="underlying_symbol" name="underlying_symbol"></select></td/tr>';
       table += '<tr><td>Event Timeframe</td><td><select id="event_timeframe" name="event_timeframe"></select></div></td/tr>';
       table += '<tr><td>Event Significance</td><td><select id="event_type" name="event_type"></select></div></td/tr>';
       table += '<tr><td>Event</td><td><select id="event_name" name="event_name"></select></div></td/tr>';
       table += '<tr><td><button onclick="updateEconomicEventPricePreview()" class="btn btn--primary">View</button></td><td class="result"></td></tr>';
       table += '</table>';

       el.html(table);

      date_select = document.querySelector('#date'),
      underlying_select = document.querySelector('#underlying_symbol'),
      event_timeframe_select = document.querySelector('#event_timeframe'),
      event_type_select = document.querySelector('#event_type'),
      event_select = document.querySelector('#event_name');


      setOptions(date_select, Object.keys(weekly_news).sort());
      setOptions(underlying_select, Object.keys(weekly_news[date_select.value]).sort());
      setOptions(event_timeframe_select, ['incoming_event','ongoing_event','past_event']);
      setOptions(event_type_select,['significant_event','insignificant_event']);
      event_selection();

      date_select.addEventListener('change', function() {
        event_selection();
      });
      underlying_select.addEventListener('change', function() {
        event_selection();
      });
      event_timeframe_select.addEventListener('change', function() {
        event_selection();
      });
      event_type_select.addEventListener('change', function() {
        event_selection();
      });

      function event_selection(){

        if(weekly_news[date_select.value][underlying_select.value][event_timeframe_select.value][event_type_select.value] == undefined){
            setOptions(event_select,['-']);
        }else{
            setOptions(event_select, Object.keys(weekly_news[date_select.value][underlying_select.value][event_timeframe_select.value][event_type_select.value]));
        }
      }

      function setOptions(dropDown, options ) {

        dropDown.innerHTML = '';
        options.forEach(function(value) {
            dropDown.innerHTML += '<option name="' + value + '">' + value + '</option>';
        })
      }
    };

    function createEconomicEventChange(id) {

       var el = \$('div#'+id);
       var table = '<table id="' + id + '" class="economic_event_table border">';
       var parameter = ['vol_change','decay_factor','duration','vol_change_before','decay_factor_before'];

       for (var i=0; i<parameter.length; i++) {
            table += '<tr><td><div class="input_field">'+parameter[i]+'  </td><td><input size="10" type="text" name='+parameter[i]+' data-lpignore="true" /></div></td/tr>';
       }
       table += '<tr><td><button onclick="compareEconomicEventPricePreview()" class="btn btn--primary">Compare</button></td><td class="result"></td></tr>';

       table += '</table>';
       el.html(table);

    }

    function compareEconomicEventPricePreview() {

        var info = \$('table#economic_event_price_preview_form');
        var date = info.find('select[name="date"]').val();
        var underlying_symbol = info.find('select[name="underlying_symbol"]').val();
        var event_timeframe = info.find('select[name="event_timeframe"]').val();
        var event_type = info.find('select[name="event_type"]').val();
        var event_name = info.find('select[name="event_name"]').val();

        var change = \$('table#economic_event_change');
        var vol_change = change.find('input[name="vol_change"]').val();
        var decay_factor = change.find('input[name="decay_factor"]').val();
        var duration  = change.find('input[name="duration"]').val();
        var vol_change_before = change.find('input[name="vol_change_before"]').val();
        var decay_factor_before = change.find('input[name="decay_factor_before"]').val();

        var result = change.find('td.result');
        result.text('processing ...');
        \$.ajax({
            url: eco_preview_upload_url,
            data: {
                update_economic_event_price_preview: "1",
                date : date,
                underlying_symbol: underlying_symbol,
                event_timeframe: event_timeframe,
                event_type: event_type,
                event_name: event_name,
                vol_change: vol_change,
                decay_factor: decay_factor,
                duration: duration,
                vol_change_before: vol_change_before,
                decay_factor_before: decay_factor_before
            },
            success: function(data) {
                var event = \$.parseJSON(data);
                if (event.error) {
                    result.text(event.error).css('color', 'var(--color-red)');
                } else {
                    if(event.headers == undefined){
                        result.text('Event not found').css('color', 'var(--color-red)');
                    }else{
                        result.text('Comparison updated').css('color', 'var(--color-green-2)');
                        updateEconomicEventPricePreview();
                        createEconomicEventPriceTable(event.headers, event.prices, 'economic_event_price_preview_updated');
                    }
                }
            }
        });
    }
