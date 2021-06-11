function WinPopupSearchClients(broker) {
    var $name_broker = $("[name=broker]");
    broker = $name_broker ? $name_broker.val() : 'CR';
    newWindow = window.open(
        '/d/backoffice/f_popupclientsearch.cgi?broker=' + broker,
        'ClientSearch',
        'width=1200,height=220,toolbar=no,directories=no,status=no,scrollbars=yes,resize=no,menubar=no'
    );
}

function CheckLoginIDformat(forminput) {
    if (forminput.value === '') {
        return true;
    }
    if (!forminput.value.match(/^\D+\d+$/)) {
        alert('The loginID is not input correctly.');
        return (false);
    }
    var $name_broker = $("[name=broker]");
    var broker = $name_broker ? $name_broker.val() : 'CR';
    if (!(new RegExp('^' + broker, 'i')).test(forminput.value)) {
        alert('The loginID should start with ' + broker + '.');
        return (false);
    }
    return true;
}

function IPWin(url) {
    newWindow = window.open(url, "IPresolver", "toolbar=no,width=700,height=480,directories=no,status=no,scrollbars=yes,resize=no,menubar=no");
}

function setPointer(theRow, thePointerColor) {
    if (thePointerColor == '' || typeof(theRow.style) == 'undefined') {
        return false;
    }
    var theCells;
    if (typeof(document.getElementsByTagName) != 'undefined') {
        theCells = theRow.getElementsByTagName('td');
    } else if (typeof(theRow.cells) != 'undefined') {
        theCells = theRow.cells;
    } else {
        return false;
    }
    var rowCellsCnt = theCells.length;
    for (var c = 0; c < rowCellsCnt; c++) {
        theCells[c].style.backgroundColor = thePointerColor;
    }
    return true;
}

function confirmDownloadCSV(day) {
    return confirm('Download CSV will auto withdraw funds from all the disabled accounts where last access day is more than ' + day + ' days. Do you still want to continue?');
}

function SetTelCategoryVisibility(contact_type) {
    var telCategory = document.getElementById('telCategory');
    var sendOutSurveyRow = document.getElementById('sendoutsurvey_row');

    if (telCategory) {
        if (contact_type == 'Telephone') {
            telCategory.style.visibility = 'visible';
            sendOutSurveyRow.style.display = '';
        } else {
            telCategory.style.visibility = 'hidden';
            sendOutSurveyRow.style.display = 'none';
        }
    }
}

function toggle_dcc_table(that) {
    if (that.title != that.value) {
        $('#dcc_' + that.name).show();
    } else {
        $('#dcc_' + that.name).hide();
    }
}

function affiliate_modification_status(that) {
    if (that.checked) {
        $('.affiliate_field').removeAttr('disabled');
    } else {
        $('.affiliate_field').attr('disabled', 'disabled');
    }
}

function parse_html_response(modal, html) {
    var div = document.createElement('div');
    div.innerHTML = html;
    var modal_title = div.querySelector('.card__label') ? div.querySelector('.card__label').innerHTML : null;
    var modal_content_list = Array.from(div.querySelectorAll('.card__content'));
    var modal_content = modal_content_list.length ? modal_content_list.filter(node => node.innerHTML)[0].innerHTML : div.innerHTML;
    modal.find('span.modal__title').html(modal_title);
    modal.find('div.modal__content').html(modal_content);
}

$(document).ready(function() {
    $('form.bo_ajax_form').unbind('submit').bind('submit', function(event) {
        var this_form = $(event.target);
        var enctype = this_form.attr('enctype');

        event.stopImmediatePropagation();

        if (this_form.attr('id') != 'paymentDCC') {
            if (!confirm('Are you sure you want to continue?')) {
                return false;
            }
        }

        event.preventDefault();

        var modal_overlay = $('body').find('div.modal_overlay');
        var modal = null;

        if (!modal_overlay.length) {
            modal_overlay = $(`
                <div class="modal_overlay" style="display:none">
                    <div class="modal">
                        <div class="modal__header">
                            <span class="modal__title"></span>
                            <button type="button" class="modal__close_btn">&times;</button>
                        </div>
                        <div class="modal__content">
                            Waiting for response from server. Please wait...1
                        </div>
                    </div>
                </div>`).appendTo($('body'));

            $('button.modal__close_btn').bind('click', function() {
                modal.css({ transform: 'translateY(30px)', opacity: 0 });
                modal_overlay.detach().delay(250);

                if (modal.find('.success_message').length > 0) {
                    this_form.find('input[type=text]').val('');
                    this_form.find('input[type=file]').val('');
                }

                modal_overlay.find('div.modal__content').html('');
            });

            modal = modal_overlay.find('div.modal');
            modal_overlay.fadeIn('fast');
            modal.css({ transform: 'translateY(0px)', opacity: 1 }).delay(250);
        } else {
            modal = modal_overlay.find('div.modal');
            modal.find('div.modal__content').html('Waiting for response from server. Please wait...2');
            modal_overlay.fadeIn('fast');
            modal.css({ transform: 'translateY(0px)', opacity: 1 }).delay(250);
        }

        if (enctype === 'multipart/form-data') {
            var all_file_inputs = this.querySelectorAll('input[type=file]');
            var data = new FormData(this);
            for (i = 0; i < all_file_inputs.length; ++i) {
                data.append(all_file_inputs[i].getAttribute('name'), all_file_inputs[i].files[0]);
            }
            $.ajax({
                type: 'POST',
                url: this_form.attr('action'),
                data: data,
                processData: false,
                contentType: false,
                success: function(response) {
                    parse_html_response(modal, response);
                },
                error: function(xmlhttp) {
                    if (xmlhttp.status) {
                        var error_message = '';
                        if (typeof xmlhttp.status !== 'undefined' && xmlhttp.status !== 200) {
                            error_message = ' (status: ' + xmlhttp.status + ')';
                        } else if (xmlhttp.responseText) {
                            error_message = ' (response: ' + xmlhttp.responseText + ')';
                        }
                        modal.find('div.modal__content').html(error_message);
                    } else {
                        modal.find('div.modal__content').html('Unknown error');
                    }
                },
                dataType: 'html'
            });
        } else {
            $.ajax({
                type: 'POST',
                url: this_form.attr('action'),
                data: getFormParams(this) + '&ajax_only=1',
                success: function(response) {
                    parse_html_response(modal, response);
                },
                error: function(xmlhttp) {
                    if (xmlhttp.status) {
                        var error_message = '';
                        if (typeof xmlhttp.status !== 'undefined' && xmlhttp.status !== 200) {
                            error_message = ' (status: ' + xmlhttp.status + ')';
                        } else if (xmlhttp.responseText) {
                            error_message = ' (response: ' + xmlhttp.responseText + ')';
                        }
                        modal.find('div.modal__content').html(error_message);
                    } else {
                        modal.find('div.modal__content').html('unknown error');
                    }
                },
                dataType: 'html'
            });
        }
    });

    var bo_form_with_files = $('form.bo_form_with_files');
    var jquery_modal_overlay = $('body').find('div.modal_overlay');
    var jquery_modal = null;

    var ajax_form_options = {
        resetForm: false,
        beforeSubmit: function() {
            // confirmation box
            if (!confirm('Are you sure you want to continue?')) {
                return false;
            }

            // append hidden field ajax_only to indicate submitted from ajax
            var ajax_only = bo_form_with_files.find('input#ajax_only');
            if (!ajax_only.length) {
                bo_form_with_files.append('<input type="hidden" name="ajax_only" value="1">');
            } else {
                ajax_only.val(1);
            }

            // create response div on the fly
            if (!jquery_modal_overlay.length) {
                jquery_modal_overlay = $(`
                    <div class="modal_overlay" style="display:none">
                    <div class="modal">
                        <div class="modal__header">
                            <span class="modal__title"></span>
                            <button type="button" class="modal__close_btn">&times;</button>
                        </div>
                        <div class="modal__content">
                            Waiting for response from server. Please wait...1
                        </div>
                    </div>
                    </div>`).appendTo($('body'));

                $('button.modal__close_btn').bind('click', function() {
                    jquery_modal.css({ transform: 'translateY(30px)', opacity: 0 });
                    jquery_modal_overlay.fadeOut().delay(250);
                });

                jquery_modal = jquery_modal_overlay.find('div.modal');
                jquery_modal_overlay.fadeIn('fast');
                jquery_modal.css({ transform: 'translateY(0px)', opacity: 1 }).delay(250);
            } else {
                jquery_modal = jquery_modal_overlay.find('div.modal');
                jquery_modal.find('div.modal__content').html('Waiting for response from server. Please wait...4');
                jquery_modal_overlay.fadeIn('fast');
                jquery_modal.css({ transform: 'translateY(0px)', opacity: 1 }).delay(250);
            }
        },
        success: function(response) {
            parse_html_response(jquery_modal, response);
        },
        error: function(jqXHR, textStatus) {
            alert('failed: ' + textStatus);
        }
    };

    bo_form_with_files.ajaxForm(ajax_form_options);

    var $draw_quant_graph = $('#draw_quant_graph');
    if ($draw_quant_graph.length > 0) {
        trigger_quant_graph();

        $draw_quant_graph.bind('click', function(event) {
            event.preventDefault();
            trigger_quant_graph();
        });
    }

    var $histogram_chart = $('#histogram_chart');
    if ($histogram_chart.length > 0) {
        displayHistogramCharts($histogram_chart);
    }

    $('#format_financial_assessment_score').on('click', function() {
        var $financial_assessment_score = $('#financial_assessment_score');
        $financial_assessment_score.after('<textarea cols=150 rows=20>' + JSON.stringify(JSON.parse($financial_assessment_score.text()), null, 4) + '</textarea>')
    });
});

function trigger_quant_graph() {
    var parts_start = $('#start').val().match(/(\d{4})\-(\d{2})\-(\d{2}) (\d{2}):(\d{2}):(\d{2})/);
    var datestring_start = ((Date.UTC(+parts_start[1], parts_start[2] - 1, +parts_start[3], +parts_start[4], +parts_start[5], +parts_start[6])) / 1000).toFixed(0);
    var parts_end = $('#end').val().match(/(\d{4})\-(\d{2})\-(\d{2}) (\d{2}):(\d{2}):(\d{2})/);
    var datestring_end = ((Date.UTC(+parts_end[1], parts_end[2] - 1, +parts_end[3], +parts_end[4], +parts_end[5], +parts_end[6])) / 1000).toFixed(0);
    $.ajax({
        type: 'POST',
        url: window.location.href.split('bpot')[0] + 'bpot_graph_json.cgi',
        data: 'shortcode=' + $('#shortcode').val() + '&currency=' + $('#currency').val() + "&seasonality_prefix=" + $("#seasonality_prefix").val() +
            '&start=' + datestring_start + '&end=' + datestring_end + '&timestep=' + $('#timestep').val(),
        success: function(response) {
            draw_quant_graph(response);
        }
    });
}

$(function() {
    $('#bulkadd_exposures').submit(function() {
        var form = $(this);

        var token_error = form.find('p.token');
        var loginids_error = form.find('p.loginids');
        var has_error = 0;

        if (form.find('#token').val().length !== 32) {
            if (!token_error.length) {
                form.append($('<p>').addClass('errorfield token').text('Token field must be 32 chars in length.'));
            }
            has_error = 1;
        } else {
            token_error.remove();
        }

        if (form.find('#loginids').val().length === 0) {
            if (!loginids_error.length) {
                form.append($('<p>').addClass('errorfield loginids').text('Some loginids must be given.'));
            }
            has_error = 1;
        } else {
            loginids_error.remove();
        }

        if (has_error) {
            return false;
        }
    });
});

$(function() {
    $('div.tooltip p').hide();
    $('div.tooltip').click(function() {
        var div = $(this);
        div.find('p').toggle('slow');
        return false;
    });
});

var setSymbolValue = function(e) {
    var underlying = $(e).find('input[name="underlying"]').val();
    var text = $(e).find('textarea[name="info_text"]').val();
    $(e).find('input[name=symbol]').val(underlying);
    $(e).find('textarea[name=text]').val(text);
    return true;
};

$(function() {
    $('.confirm_crypto_action').on('click', function() {
        return confirm('Are you sure?');
    });
});

/////////////////////////////////////////////////////////////////
// Purpose   : Generate form's parameters in the format that is
//             required by XMLHttpRequest.
// Return    : Parameters string e.g. var1=val1&var2=var2
// Parameters: Targeted form object
/////////////////////////////////////////////////////////////////
function getFormParams(form_obj) {
    var params_arr = [];
    if (!form_obj) return '';
    var elem = form_obj.elements;

    var j = 0;
    for (var i = 0; i < elem.length; i++) {
        if (elem[i].name) {
            if (elem[i].nodeName == 'INPUT' && elem[i].type.match(/radio|checkbox/) && !elem[i].checked) {
                continue; // skip if it is not checked
            }
            params_arr[j] = elem[i].name + '=' + encodeURIComponent(elem[i].value);
            j++;
        }
    }

    return params_arr.join('&');
}

/**
 * Adds thousand separators for numbers.
 *
 * @param given_num: any number (int or float)
 * @return string
 */
function virgule(given_num) {
    var parts = given_num.toString().split(".");
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    return parts.join(".");
}

function draw_quant_graph(data) {
    var show_barrier_2 = false;
    for (i = 0; i < data.data['Barriers(s)'].length; i++) {
        data.data['Barriers(s)'][i] = parseFloat(data.data['Barriers(s)'][i]);
        data.data['Barriers2'][i] = parseFloat(data.data['Barriers2'][i]);
        if (data.data['Barriers(s)'][i] !== data.data['Barriers2'][i]) {
            show_barrier_2 = true;
            break;
        }
    }
    for (i = 0; i < data.data.Spot.length; i++) {
        data.data.Spot[i] = parseFloat(data.data.Spot[i]);
    }
    for (i = 0; i < data.times.length; i++) {
        data.times[i] = parseInt(data.times[i]) * 1000;
    }
    var $quant_graph = $('#quant_graph');
    $quant_graph.empty();
    $quant_graph.highcharts({
        title: {
            text: data.underlying_name,
            x: -20 //center
        },
        subtitle: {
            text: data.time_title,
            x: -20
        },
        chart: {
            height: 500
        },
        legend: {
            align: 'right',
            verticalAlign: 'top',
            layout: 'vertical',
            floating: false,
            x: 0,
            y: 200
        },
        tooltip: {
            xDateFormat: '%A, %b %e, %H:%M:%S GMT'
        },
        yAxis: [{ // Primary yAxis
            title: {
                text: 'Values'
            },
            labels: {
                format: '{value:.3f}'
            }
        }, { // Secondary yAxis
            min: -5,
            max: 100,
            tickInterval: 5,
            title: {
                text: 'Percentage'
            },
            labels: {
                format: '{value}%'
            },
            opposite: true
        }],
        xAxis: {
            type: 'datetime',
            categories: data.times,
            labels: { overflow: "justify", format: "{value:%H:%M:%S}" }
        }
    });
    for (var key in data.data) {
        if (key === 'Spot' || key === 'Barriers(s)') {
            $quant_graph.highcharts().addSeries({
                name: key,
                data: data.data[key]
            });
        } else if (key === 'BS value' || key === 'Bet value' || key === 'Bid value' || key === 'Pricing IV' || key === 'Pricing mu') {
            $quant_graph.highcharts().addSeries({
                yAxis: 1,
                name: key,
                data: data.data[key],
                tooltip: {
                    valueSuffix: '%'
                }
            });
        }
    }
    /* yAxis0Extremes = chart.yAxis[0].getExtremes();
    yAxisMaxMinRatio = yAxis0Extremes.max / yAxis0Extremes.min;
    yAxis1Extremes = chart.yAxis[1].getExtremes();
    yAxis1Min = (yAxis1Extremes.max / yAxisMaxMinRatio).toFixed(0);
    chart.yAxis[1].setExtremes(yAxis1Min, yAxis1Extremes.max); */
}

/**
 * Get histogram data out of xy data
 * @param   {Array} data  Array of tuples [x, y]
 * @param   {Number} step Resolution for the histogram
 * @returns {Array}       Histogram data
 */
function getHistogramData(data, step) {
    var histo = {},
        x,
        i,
        arr = [];

    // Calculate step
    if (!step) {
        var values = data.map(function(elt) { return elt[0]; });
        step = (Math.max.apply(null, values) - Math.min.apply(null, values)) / 10 || 5;
    }

    // Group down
    for (i = 0; i < data.length; i++) {
        x = Math.floor(data[i][0] / step) * step;
        if (!histo[x]) {
            histo[x] = 0;
        }
        histo[x]++;
    }

    // Make the histo group into an array
    for (x in histo) {
        if (histo.hasOwnProperty((x))) {
            arr.push([parseFloat(x), histo[x]]);
        }
    }

    // Finally, sort the array
    arr.sort(function(a, b) {
        return a[0] - b[0];
    });

    return arr;
}

function displayHistogramCharts($container) {
    $.ajax({
        type: 'GET',
        url: '/d/backoffice/f_dailyico_graph.cgi',
        success: function(response) {
            $container.empty();
            Object.keys(response).forEach(function(key) {
                $container.append($('<div/>', { id: 'histogram_chart_' + key }));
                var data = response[key];
                // convert to number
                data = data.map(function(ar) {
                    return ar.map(function(v) { return +v; });
                });
                drawHistogramChart(data, key);
            });
        }
    });
}

function drawHistogramChart(data, key) {
    $('#histogram_chart_' + key).highcharts({
        chart: {
            type: 'column'
        },
        title: {
            text: 'Histogram: Open ICO deals in ' + key
        },
        xAxis: {
            title: {
                text: 'Bid price per token in ' + key
            },
            gridLineWidth: 1
        },
        yAxis: [{
            title: {
                text: 'Count of deals'
            }
        }, {
            opposite: true,
            title: {
                text: 'Number of tokens'
            }
        }],
        series: [{
            name: 'Histogram',
            type: 'column',
            data: getHistogramData(data),
            pointPadding: 0,
            groupPadding: 0,
            pointPlacement: 'between'
        }, {
            name: 'XY data',
            type: 'scatter',
            data: data,
            yAxis: 1,
            marker: {
                radius: 1.5
            }
        }]
    });
}

function smoothScroll(target = 'body', duration = 500, offset = 0) {
    $([document.documentElement, document.body]).animate({
        scrollTop: $(target)[0].offsetTop + offset,
    }, duration);
}

function debounce(func, wait, immediate) {
    let timeout;
    const delay = wait || 500;
    return function(...args) {
        const context = this;
        const later = () => {
            timeout = null;
            if (!immediate) func.apply(context, args);
        };
        const call_now = immediate && !timeout;
        clearTimeout(timeout);
        timeout = setTimeout(later, delay);
        if (call_now) func.apply(context, args);
    };
}

function createSectionLinks() {
    const highlight_class = 'highlight';
    const el_top_bar = document.getElementById('top_bar');
    const el_main_title = document.getElementById('main_title');

    if (!el_top_bar || !el_main_title) return;

    const top_margin = el_top_bar.clientHeight + el_main_title.clientHeight + 32;
    const all_sections = [];

    document.querySelectorAll('.card__label').forEach(el_title => {
        const text = el_title.textContent.toLowerCase();
        const nav_link = el_title.getAttribute('data-nav-link');
        // Set anchor_name to the section's data-nav-link value (if exists), otherwise default to section title
        const anchor_name = nav_link ? nav_link.replace(/[^a-z0-9]/ig, '_') : text.replace(/[^a-z0-9]/ig, '_');

        const el_anchor = document.createElement('a');
        el_anchor.setAttribute('name', anchor_name);
        el_title.prepend(el_anchor);

        const el_link = document.createElement('a');
        el_link.setAttribute('href', `#${anchor_name}`);
        el_link.setAttribute('class', 'link');
        // Set the link's textContent to the section's data-nav-link value (if exists), otherwise default to section title
        el_link.textContent = nav_link ? nav_link : text;
        el_link.addEventListener('click', (e) => {
            e.preventDefault();
            smoothScroll(el_anchor, null, -top_margin);
            setSection({ name: anchor_name, link: el_link, anchor: el_anchor });
            location.hash = anchor_name;
            el_title.classList.add(highlight_class);
            setTimeout(() => { el_title.classList.remove(highlight_class); }, 2000);
        });

        el_top_bar.append(el_link);

        all_sections.push({ name: anchor_name, link: el_link, anchor: el_anchor });
    });

    setSectionLinksScrolling();

    let last_section;
    const setSection = (current_section = null) => { last_section = setCurrentSection(all_sections, top_margin, last_section, current_section); };
    window.addEventListener('scroll', debounce(() => setSection(null), 100), true);
    setSection();
}

function setSectionLinksScrolling() {
    $('#top_bar').on('mousemove', function(e) {
        const container = $(this);
        const mouse_x = e.pageX - container.offset().left;
        const offset = 40; // specifies the areas from left/right sides that capture mouse movement for scrolling
        const distance = (mouse_x < offset ? mouse_x : container.width() - mouse_x) ;
        if (distance < offset) {
            const direction = mouse_x - container.offset().left < container.width() / 2 ? '-' : '+';
            // distance multiplication makes the scroll faster as mouse pointer
            // gets closer to the edges of screen, and slower as moves away.
            container.stop(true).animate({ scrollLeft: `${direction}=${200 - distance * 3}` }, 1000, 'linear');
        }
    }).on('mouseleave', function() {
        $(this).stop(true);
    });
}

function setCurrentSection(all_sections, top_margin, last_section, current_section) {
    const current_position = document.body.scrollTop;

    if (!current_section && current_position > 230) {
        // ignore certain top scrollY position
        current_section = all_sections.filter(section => section.anchor.offsetTop - top_margin - top_margin < current_position).slice(-1)[0];
    }

    if (!current_section) {
        current_section = last_section; // inialize current_section
    };

    if (current_section !== last_section) {
        if (last_section) {
            last_section.link.classList.remove('active');
        }
        if (current_section) {
            current_section.link.classList.add('active');
        }
    }

    return current_section;
}

function initCopyText() {
    document.querySelectorAll('.copy-on-click').forEach(el => {
        el.classList.add('tooltip-nowrap');
        el.setAttribute('tooltip', 'Click to copy');
        el.addEventListener('click', (e) => {
            navigator.clipboard.writeText(e.target.textContent);
        });
    });
}

function initCardToggle() {
    document.querySelectorAll('div.card__label.toggle').forEach(el_label => {
        el_label.addEventListener('click', e => {
            e.target.classList[e.target.classList.contains('collapsed') ? 'remove' : 'add']('collapsed');
        });
    });
}

function initTableToggle() {
    document.querySelectorAll('table.toggle').forEach(el_table => {
        el_table.querySelector('thead').addEventListener('click', e => {
            el_table.classList[el_table.classList.contains('collapsed') ? 'remove' : 'add']('collapsed');
        });
    });
}

function initThemeSwitcher() {
    const toggle_theme = document.getElementById('theme_switcher');
    toggle_theme.addEventListener('change', function(e) {
        const theme = e.target.checked ? 'dark' : 'light';
        document.documentElement.setAttribute('data-theme', theme);
        localStorage.setItem('theme', theme);
    }, false);
}

let clock_interval;

function initGMTClock() {
    const clock = document.getElementById('gmt_clock');

    function timer() {
        const now = new Date();
        clock.innerHTML = now.toISOString().split('.')[0].replace('T', ' ') + ' GMT';
        clock.setAttribute('tooltip', now.toString());
    };

    timer(); // run timer onload
    clock_interval = setInterval(timer, 1000);
}

$(function() {
    createSectionLinks();
    initCopyText();
    initCardToggle();
    initTableToggle();
    $(`.sidebar a[href*="${window.location.pathname}"]`).parent().addClass('active');
    initThemeSwitcher();
    initGMTClock();
});


window.onunload = function() {
    clearInterval(clock_interval);
};
