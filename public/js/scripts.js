var frmLogin,
    txtEmail,
    txtPass ;
var errClass = 'err';

window.onload = function() {
    frmLogin = document.getElementById('frmLogin');
    txtEmail = document.getElementById('txtEmail');
    txtPass  = document.getElementById('txtPass' );

    if (frmLogin) {
        frmLogin.addEventListener('submit', function(e) {
            if(!validate()) {
                e.preventDefault();
                return false;
            } else {
                $('#btnLogin').attr('disabled', 'disabled');
            }
        });
    }
    if (txtEmail) {
        txtEmail.addEventListener('input', function(e) {
            if(txtEmail.classList.contains('hadError')) {
                validateEmail();
            }
        });
        txtEmail.addEventListener('change', function(e) {
            validateEmail();
        });
    }
    if (txtPass) {
        txtPass.addEventListener('input', function(e) {
            if(txtPass.classList.contains('hadError')) {
                validatePass();
            }
        });
        txtPass.addEventListener('change', function(e) {
            validatePass();
        });
    }
};

function validate() {
    var validEmail = validateEmail(),
        validPass  = validatePass();
    return validEmail && validPass;
}

function validateEmail() {
    return validateField(txtEmail, new RegExp(/^\w+([\+\.-]?\w+)*@\w+([\.-]?\w+)*(\.\w{2,4})+$/));
}

function validatePass() {
    return validateField(txtPass, new RegExp(/^[ -~]{6,25}$/));
}

function validateField(element, regex) {
    var hasError = true;
    if(element) {
        var value = (element.value || '').trim();
        if (value && regex.test(value)) {
            hasError = false;
        }
    }
    setValidationStyle(element, hasError);
    return !hasError;
}

function setValidationStyle(element, hasError) {
    if(hasError) {
        element.classList.add(errClass);
    }
    else {
        element.classList.remove(errClass);
    }
    if(element.classList.contains(errClass)) {
        element.classList.add('hadError');
    }
}
