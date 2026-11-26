self.addEventListener('push', (e) => {
  let d = {}; try { d = e.data.json(); } catch (x) {}
  e.waitUntil(self.registration.showNotification(d.title || 'كار زون', { body: d.body || '', dir: 'rtl', lang: 'ar', data: { url: d.url || '' } }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const u = self.registration.scope + (e.notification.data && e.notification.data.url || '');
  e.waitUntil(clients.matchAll({ type: 'window' }).then((l) => { for (const c of l) { if ('focus' in c) { c.navigate(u); return c.focus(); } } return clients.openWindow(u); }));
});
