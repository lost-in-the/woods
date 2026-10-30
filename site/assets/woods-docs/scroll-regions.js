/* Table overflow only. Just the Docs owns menu, search, anchors and code copying. */
(() => {
  'use strict';

  const regions = Array.from(document.querySelectorAll('.main-content .table-wrapper'));
  const owned = new WeakMap();

  const update = (region) => {
    if (region.scrollWidth > region.clientWidth + 1) {
      const attributes = owned.get(region) || [];
      const caption = region.querySelector('caption');
      const label = caption ? caption.textContent.trim() : '';
      const defaults = { tabindex: '0', role: 'region', 'aria-label': label || 'Scrollable table' };
      if (region.hasAttribute('aria-labelledby')) delete defaults['aria-label'];
      Object.entries(defaults).forEach(([name, value]) => {
        if (!region.hasAttribute(name)) {
          region.setAttribute(name, value);
          attributes.push(name);
        }
      });
      owned.set(region, attributes);
    } else {
      (owned.get(region) || []).forEach((name) => region.removeAttribute(name));
      owned.delete(region);
    }
  };

  const updateAll = () => regions.forEach(update);
  if (window.ResizeObserver) {
    const observer = new ResizeObserver(updateAll);
    regions.forEach((region) => observer.observe(region));
  } else {
    window.addEventListener('resize', updateAll, { passive: true });
  }
  if (document.fonts) document.fonts.ready.then(updateAll);
  updateAll();
})();
