// The theme switch: follows the system until the visitor picks one, then remembers it.
(function () {
  var root = document.documentElement, button = document.getElementById('theme');
  function dark() {
    return root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
  }
  function label() { button.setAttribute('aria-label', dark() ? 'Switch to light mode' : 'Switch to dark mode'); }
  button.hidden = false;
  label();
  button.addEventListener('click', function () {
    root.dataset.theme = dark() ? 'light' : 'dark';
    try { localStorage.setItem('theme', root.dataset.theme); } catch (e) {}
    label();
  });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', label);
})();
