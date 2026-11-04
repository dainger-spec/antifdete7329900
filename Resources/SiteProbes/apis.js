// local: storage quota, permission states, media devices, voices and other APIs a WKWebView app
// may answer differently from Safari (scripts/live_compare.py)
const out = {};
const settle = (p, ms) => Promise.race([p, new Promise((r) => setTimeout(() => r('timeout'), ms))]);
try { out.quota = (await navigator.storage.estimate()).quota; } catch (e) { out.quota = 'error ' + e.name; }
for (const name of ['geolocation', 'notifications', 'camera', 'microphone', 'persistent-storage', 'screen-wake-lock', 'midi', 'clipboard-read']) {
  try { out['permission.' + name] = (await settle(navigator.permissions.query({ name }), 2000)).state; } catch (e) { out['permission.' + name] = 'error ' + e.name; }
}
try {
  const devices = await settle(navigator.mediaDevices.enumerateDevices(), 3000);
  out.devices = devices === 'timeout' ? 'timeout' : devices.map((d) => d.kind + (d.label ? '+label' : '') + (d.deviceId ? '+id' : '')).join(',');
} catch (e) { out.devices = 'error ' + e.name; }
out.voices = await new Promise((resolve) => {
  const count = () => (window.speechSynthesis ? speechSynthesis.getVoices().length : -1);
  if (count() > 0) return resolve(count());
  setTimeout(() => resolve(count()), 1500);
});
out.notification = typeof Notification === 'function' ? Notification.permission : 'none';
out.share = [typeof navigator.share, typeof navigator.canShare].join();
out.privateClickMeasurement = 'attributionSourceId' in HTMLAnchorElement.prototype;
out.storageAccess = typeof document.hasStorageAccess === 'function' ? String(await document.hasStorageAccess()) : 'none';
out.webauthn = window.PublicKeyCredential && PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable
  ? String(await settle(PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(), 3000)) : 'none';
out.persisted = navigator.storage && navigator.storage.persisted ? String(await navigator.storage.persisted()) : 'none';
return out;
