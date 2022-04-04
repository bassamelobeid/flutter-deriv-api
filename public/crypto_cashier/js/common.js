

function learnMore() {
    var x = document.getElementById('LearnMore');

    if ( !x.style.display || x.style.display === 'none') {
        x.style.display = 'block';
    } else {
        x.style.display = 'none';
    }
}

setTimeout(function() {
    window.location.href = window.location.href;
}, 5 * 60 * 1000);

