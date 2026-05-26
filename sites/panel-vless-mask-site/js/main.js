(() => {
  const button = document.querySelector('[data-static-action]');
  const hint = document.getElementById('page-hint');
  if (!button || !hint) return;
  button.addEventListener('click', () => {
    hint.textContent = 'Public sign in is not available from this page.';
  });
})();
