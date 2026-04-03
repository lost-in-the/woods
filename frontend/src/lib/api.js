const basePath =
  document.querySelector('meta[name="woods-base-path"]')?.content || '';

export async function fetchJSON(endpoint) {
  const res = await fetch(`${basePath}/api/${endpoint}`);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

export function safeKey(identifier) {
  return identifier.replace(/::/g, '__').replace(/[^a-zA-Z0-9_-]/g, '_');
}
