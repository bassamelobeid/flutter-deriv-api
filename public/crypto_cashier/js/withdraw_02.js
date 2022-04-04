var FormValidator = (function() {
    var errors = {};

    var validate = {
        address: function(field) { return validateAddress(field); },
        amount : function(field) { return field.checkValidity() && validateAmount(field.value, precision) && parseFloat(field.value) >= minimum; },
    };

    var elements, minimum, precision;

    function init() {
        elements = FormElements.get();
        elements.form.addEventListener('submit', function(e) {
            if (Object.keys(errors).length) {
                e.preventDefault();
            }
        });

        minimum   = elements.amount.getAttribute('data-minimum');
        precision = elements.amount.getAttribute('data-precision');

        Object.keys(validate).forEach(function(field_name) {
            var el = elements[field_name];
            el.addEventListener('input', function (event) {
                updateDisplay(el);
            });
            checkField(el);
        });

        // Auto-hide the error
        setTimeout(function() {
            var el_form_error = elements.form.querySelector('.form-error');
            if (el_form_error) {
                el_form_error.setAttribute('style', 'display: none');
            }
        }, 5000);
    }

    function validateAmount(value, precision) {
        precision = typeof precision === 'undefined' || isNaN(precision) ? 8 : precision;
        var re = new RegExp('^\\d{1,15}' + (precision > 0 ? '(\\.\\d{1,' + precision + '})?' : '') + '$');
        return re.test(value);
    }
    
    function validateAddress(field) {
        var parent   =   field.parentNode;
        if(!(field.value || '').length) {
            return true;
        }
        var is_valid_check = field.checkValidity();
        var is_valid_format = validateAddressFormat(field.value, field.dataset.currency_code);

        parent.querySelector('.format-error').classList[is_valid_format ? 'remove' : 'add']('show-error');
        parent.querySelector('.length-error').classList[(field.value || '').length && !is_valid_check && is_valid_format ? 'add' : 'remove']('show-error');

        return (is_valid_check && is_valid_format);
    }
    
    function validateAddressFormat(value, currency_code) {
        if(currency_code != 'USDT' || !(value || '').length) {
            return true;
        }
        var re = new RegExp('^(bc|tb)'); // check if USDT address provided is not a bech32
        return !re.test(value);
    }

    function checkField(el_field) {
        const field_name = el_field.name;
        const is_valid   = validate[field_name](el_field);

        if (is_valid) {
            delete errors[field_name];
        } else {
            errors[field_name] = 1;
        }

        return is_valid;
    }

    function updateDisplay(el_field) {
        var parent = el_field.parentNode;

        if (checkField(el_field)) {
            parent.classList.remove('error');
            parent.querySelector('.error-msg').classList.remove('show-error');
        } else {
            parent.classList.add('error');
            parent.querySelector('.error-msg').classList.add('show-error');
        }

        if (Object.keys(errors).length) {
            elements.submit.setAttribute('disabled', 'disabled');
        } else {
            setTimeout(function() {
                elements.submit.getAttribute('disabled'); // Workaround for iOS
                elements.submit.removeAttribute('disabled');
            }, 100);
        }
    }

    return {
        init: init,
    };
})();

var FormElements = (function(){
    var elements = {};

    function initElements() {
        elements.form = document.getElementById('frm_withdraw');
        var field_names = ['address', 'amount', 'submit'];
        field_names.forEach(function(name) {
            elements[name] = frm_withdraw.querySelector('#withdraw_' + name);
        });
    }

    return {
        get: function(key) {
            if (!Object.keys(elements).length) {
                initElements();
            }
            return key ? elements[key] : elements;
        },
    };
})();

document.addEventListener('DOMContentLoaded', FormValidator.init);

function updateButton(form) {
    form.querySelector('.btn-withdraw-cancel').setAttribute('style', 'display: none;');
    form.querySelector('.btn-animated').setAttribute('style', 'display: initial;');
    return true;
}
