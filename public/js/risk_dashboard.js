$(window).on('load',function() {
        $( "#rd-tabs" ).tabs();
        var risk_dashboard = $('#rd-summary');

        risk_dashboard.delegate('tr, li', 'mouseover', function() {
            var elt = $(this);
            var classname = elt.attr('class');
            if (classname) {
                risk_dashboard.find('.'+classname).addClass('highlight');
            }
        })
        .delegate('tr, li', 'mouseout', function() {
            var elt = $(this);
            var loginid;
            var classes = elt.attr('class').match(/[A-Z]+\d+/) || [];
            if (classes.length) {
                loginid = classes[0];
                risk_dashboard.find('.'+loginid).removeClass('highlight');
            }
        });
});
