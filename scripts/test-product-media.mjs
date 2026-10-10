import assert from 'node:assert/strict';
import { PRODUCT_MEDIA_BUCKET, PRODUCT_PHOTO_MAX_BYTES, productMediaError, uploadProductPhoto, validateProductPhoto, validateProductPhotoUrl, waitForProductPhoto } from '../src/lib/product-media.js';

let checks = 0;
const check = (value, expected) => { assert.deepEqual(value, expected); checks += 1; };
async function rejected(action, code) { await assert.rejects(action, error => error.message === code); checks += 1; }
const photo = (type, bytes, name = '顧客提供的產品.jpg') => new File([Uint8Array.from(bytes)], name, { type });
const jpeg = photo('image/jpeg', [255, 216, 255, 224, 0, 16]);
const png = photo('image/png', [137, 80, 78, 71, 13, 10, 26, 10]);
const webp = photo('image/webp', [82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80]);
check(PRODUCT_MEDIA_BUCKET, 'product-media');
check(await validateProductPhoto(jpeg), { mime: 'image/jpeg', extension: 'jpg' });
check(await validateProductPhoto(png), { mime: 'image/png', extension: 'png' });
check(await validateProductPhoto(webp), { mime: 'image/webp', extension: 'webp' });
await rejected(() => validateProductPhoto(photo('image/svg+xml', [60, 115, 118, 103])), 'PRODUCT_PHOTO_TYPE');
await rejected(() => validateProductPhoto(photo('image/jpeg', [60, 115, 118, 103])), 'PRODUCT_PHOTO_INVALID');
await rejected(() => validateProductPhoto(photo('image/png', [255, 216, 255])), 'PRODUCT_PHOTO_INVALID');
await rejected(() => validateProductPhoto(photo('image/jpeg', [])), 'PRODUCT_PHOTO_SIZE');
await rejected(() => validateProductPhoto({ type: 'image/jpeg', size: PRODUCT_PHOTO_MAX_BYTES + 1 }), 'PRODUCT_PHOTO_SIZE');
await rejected(() => validateProductPhoto({ type: 'image/jpeg', size: 12, slice: () => ({ arrayBuffer: async () => { throw new Error('file unreadable'); } }) }), 'PRODUCT_PHOTO_INVALID');
check(validateProductPhotoUrl('  https://cdn.example.test/photo.jpg  '), 'https://cdn.example.test/photo.jpg');
check(validateProductPhotoUrl(''), '');
check(validateProductPhotoUrl('http://cdn.example.test/photo.png'), 'http://cdn.example.test/photo.png');
for (const url of ['javascript:alert(1)', 'data:image/svg+xml,<svg/>', 'ftp://example.test/photo.jpg', 'https://user:password@example.test/a.jpg', '//example.test/a.jpg', 'broken']) {
  assert.throws(() => validateProductPhotoUrl(url), /PRODUCT_PHOTO_URL/); checks += 1;
}

let calls = [], uploadCount = 0;
const random = { randomUUID: () => '12345678-1234-4123-8123-123456789012' };
const client = { storage: { from(bucket) { calls.push(['bucket', bucket]); return {
  async upload(path, file, options) { uploadCount += 1; calls.push(['upload', path, file.name, options]); return { data: { path }, error: null }; },
  getPublicUrl(path) { calls.push(['url', path]); return { data: { publicUrl: `https://storage.example.test/${path}` } }; },
}; } } };
check(await uploadProductPhoto(jpeg, { client, random }), { path: 'products/12345678-1234-4123-8123-123456789012.jpg', url: 'https://storage.example.test/products/12345678-1234-4123-8123-123456789012.jpg' });
check(calls[1], ['upload', 'products/12345678-1234-4123-8123-123456789012.jpg', jpeg.name, { contentType: 'image/jpeg', cacheControl: '31536000', upsert: false }]);
check(uploadCount, 1);
// A failing validation must not request the Storage API.
calls = [];
await rejected(() => uploadProductPhoto(photo('image/svg+xml', [60]), { client, random }), 'PRODUCT_PHOTO_TYPE');
check(calls.length, 0);
const failedClient = { storage: { from: () => ({ upload: async () => ({ data: null, error: { message: 'private storage detail' } }) }) } };
await rejected(() => uploadProductPhoto(jpeg, { client: failedClient, random }), 'PRODUCT_PHOTO_UPLOAD_FAILED');
const thrownClient = { storage: { from: () => ({ upload: async () => { throw new Error('secret header'); } }) } };
await rejected(() => uploadProductPhoto(jpeg, { client: thrownClient, random }), 'PRODUCT_PHOTO_UPLOAD_FAILED');
const noUrlClient = { storage: { from: () => ({ upload: async () => ({ data: {}, error: null }), getPublicUrl: () => ({ data: {} }) }) } };
await rejected(() => uploadProductPhoto(jpeg, { client: noUrlClient, random }), 'PRODUCT_PHOTO_PUBLIC_URL');
let resolveUpload;
const pending = new Promise(resolve => { resolveUpload = resolve; });
await rejected(() => waitForProductPhoto(pending, 1), 'PRODUCT_PHOTO_UPLOAD_TIMEOUT');
resolveUpload({ url: 'https://storage.example.test/done.jpg' });
check(await waitForProductPhoto(pending, 100), { url: 'https://storage.example.test/done.jpg' });
check(productMediaError(new Error('PRODUCT_PHOTO_UPLOAD_FAILED'), () => 'fallback').includes('商品尚未儲存'), true);
check(productMediaError(new Error('not-media'), () => 'fallback'), 'fallback');
console.log(`Product media checks passed: ${checks}`);
