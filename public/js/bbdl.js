$(function(){
    $("form[id^='corp_action_']").submit(function(){
        form = $(this);
        $.ajax({
            url: "corporate_actions.cgi",
            data: form.serialize(),
            type: 'POST',
            dataType: 'json',
            success: function(data) {
                var message;
                if (data.success) {
                    message = 'Updated';
                } else {
                    message = 'Update failed. Reason: ' + data.reason;
                }
                $("div[class=button_"+data.id+"]").hide();
                $("div[class=status_"+data.id+"]").text(message);
            },
            error: function(jqXHR, textStatus) {alert(textStatus)},
        });
        return false;
    });
});
