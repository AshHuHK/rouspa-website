import { createRequestId } from './request-id.js';

export const PRODUCT_MEDIA_BUCKET = 'product-media';
export const PRODUCT_PHOTO_MAX_BYTES = 5 * 1024 * 1024;
export const PRODUCT_PHOTO_ACCEPT = 'image/jpeg,image/png,image/webp';
const imageTypes = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
const mediaMessages = {
  PRODUCT_PHOTO_TYPE: '請選擇 JPG、PNG 或 WebP 產品照片。',
  PRODUCT_PHOTO_SIZE: '產品照片不得超過 5 MB，且不能是空白檔案。',
  PRODUCT_PHOTO_INVALID: '照片內容與圖片格式不符，請重新選擇有效照片。',
  PRODUCT_PHOTO_URL: '照片網址請使用完整的 https:// 或 http:// 圖片網址。',
  PRODUCT_PHOTO_UPLOAD_FAILED: '照片上傳失敗，商品尚未儲存。請檢查網路與目錄權限後重試。',
  PRODUCT_PHOTO_UPLOAD_TIMEOUT: '照片上傳仍未完成，商品尚未儲存。請稍後按儲存重試；會沿用同一次上傳。',
  PRODUCT_PHOTO_PUBLIC_URL: '無法取得產品照片網址，商品尚未儲存。請重試。',
};

export function productMediaError(error, fallback) {
  return mediaMessages[error?.message] || fallback(error);
}

export function validateProductPhotoUrl(value) {
  const text = String(value || '').trim();
  if (!text) return '';
  try {
    const url = new URL(text);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) throw new Error();
    return url.href;
  } catch {
    throw new Error('PRODUCT_PHOTO_URL');
  }
}

export async function validateProductPhoto(file) {
  if (!file || !Number.isFinite(file.size) || file.size <= 0 || file.size > PRODUCT_PHOTO_MAX_BYTES) throw new Error('PRODUCT_PHOTO_SIZE');
  const mime = String(file.type || '').toLowerCase();
  if (!imageTypes[mime]) throw new Error('PRODUCT_PHOTO_TYPE');
  let bytes;
  try { bytes = new Uint8Array(await file.slice(0, 12).arrayBuffer()); }
  catch { throw new Error('PRODUCT_PHOTO_INVALID'); }
  const jpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = [137, 80, 78, 71, 13, 10, 26, 10].every((value, index) => bytes[index] === value);
  const webp = [82, 73, 70, 70].every((value, index) => bytes[index] === value) && [87, 69, 66, 80].every((value, index) => bytes[index + 8] === value);
  if (!(mime === 'image/jpeg' && jpeg || mime === 'image/png' && png || mime === 'image/webp' && webp)) throw new Error('PRODUCT_PHOTO_INVALID');
  return { mime, extension: imageTypes[mime] };
}

export async function uploadProductPhoto(file, { client, random = globalThis.crypto } = {}) {
  const { mime, extension } = await validateProductPhoto(file);
  const path = `products/${createRequestId(random)}.${extension}`;
  const bucket = client.storage.from(PRODUCT_MEDIA_BUCKET);
  let result;
  try { result = await bucket.upload(path, file, { contentType: mime, cacheControl: '31536000', upsert: false }); }
  catch { throw new Error('PRODUCT_PHOTO_UPLOAD_FAILED'); }
  if (result?.error || !result?.data) throw new Error('PRODUCT_PHOTO_UPLOAD_FAILED');
  const url = bucket.getPublicUrl(path)?.data?.publicUrl;
  if (!url) throw new Error('PRODUCT_PHOTO_PUBLIC_URL');
  return { path, url: validateProductPhotoUrl(url) };
}

// Keep the original upload promise in the editor. A deadline ends the UI wait,
// while a retry waits for that same operation instead of uploading another file.
export async function waitForProductPhoto(uploadPromise, timeoutMs = 45000) {
  let timer;
  try {
    return await Promise.race([
      uploadPromise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('PRODUCT_PHOTO_UPLOAD_TIMEOUT')), timeoutMs); }),
    ]);
  } finally { clearTimeout(timer); }
}
