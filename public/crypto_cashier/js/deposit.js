function initQRCode() {
    new QRCode(document.getElementById('qrcode'), {
        text        : document.getElementById('deposit_address').textContent,
        width       : 160,
        height      : 160,
        correctLevel: QRCode.CorrectLevel.H,
    });
}

function initCopyText() {
    document.querySelectorAll('.copy-on-click').forEach(function(el) {
        el.addEventListener('click', function(e) {
            // A workaround to address the issue with Cross-Origin IFrame on `navigator.clipboard.writeText`
            var selection = window.getSelection();
            var range     = document.createRange();
            range.selectNodeContents(e.target);
            selection.removeAllRanges();
            selection.addRange(range);
            document.execCommand('copy');
            selection.removeAllRanges();

            e.target.classList.add('progress');
            setTimeout(function() { e.target.classList.remove('progress'); }, 300);

            // show copy confirmation message for few seconds
            let copyMessageElem = document.getElementById("deposit_address_copy_confirm");

            if (copyMessageElem){
                copyMessageElem.style.display = '';

                setTimeout(function() {
                    copyMessageElem.style.display = 'none';
                }, 1000);
            }
        });
    });
}

document.addEventListener('DOMContentLoaded', function() {
    initQRCode();
    initCopyText();
});
