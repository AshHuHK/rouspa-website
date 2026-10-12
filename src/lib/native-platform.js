import { Capacitor } from '@capacitor/core';

export const PUBLIC_WEBSITE_ORIGIN = 'https://www.rouspa.tw';
export const NATIVE_OPERATIONS_ORIGIN = 'capacitor://localhost';
export const NATIVE_CATCHUP_EVENT = 'rouspa:native-catchup';

export function isNativeOperationsApp() {
  return Capacitor.isNativePlatform();
}

export function publicWebsiteUrl(path = '/') {
  return new URL(path, `${PUBLIC_WEBSITE_ORIGIN}/`).href;
}

export function operationsApiUrl(path) {
  const normalized = path.startsWith('/') ? path : `/${path}`;
  return isNativeOperationsApp() ? `${PUBLIC_WEBSITE_ORIGIN}${normalized}` : normalized;
}

function safeFilename(name) {
  return String(name || 'ROU-SPA-export')
    .replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_')
    .slice(0, 180);
}

function browserDownload(name, content, mimeType) {
  const blob = content instanceof Blob ? content : new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = name;
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function toBase64(content) {
  const blob = content instanceof Blob ? content : new Blob([content]);
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = '';
  const chunk = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunk) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunk));
  }
  return btoa(binary);
}

export async function saveDownload(name, content, mimeType = 'application/octet-stream') {
  const filename = safeFilename(name);
  if (!isNativeOperationsApp()) {
    browserDownload(filename, content, mimeType);
    return { shared: false };
  }

  const [{ Filesystem, Directory, Encoding }, { Share }] = await Promise.all([
    import('@capacitor/filesystem'),
    import('@capacitor/share'),
  ]);
  const text = typeof content === 'string';
  let wroteFile = false;
  let operationError = null;
  let cleanupError = null;
  try {
    const result = await Filesystem.writeFile({
      path: filename,
      data: text ? content : await toBase64(content),
      directory: Directory.Cache,
      ...(text ? { encoding: Encoding.UTF8 } : {}),
    });
    wroteFile = true;
    await Share.share({
      title: filename,
      files: [result.uri],
      dialogTitle: `儲存或分享 ${filename}`,
    });
  } catch (error) {
    operationError = error;
  } finally {
    if (wroteFile) {
      try {
        await Filesystem.deleteFile({ path: filename, directory: Directory.Cache });
      } catch (error) {
        cleanupError = error;
      }
    }
  }
  if (operationError && cleanupError) throw new Error('檔案無法儲存或分享，且暫存檔清理失敗。請關閉並重新開啟 App 後再重試。', { cause: operationError });
  if (operationError) throw new Error('檔案無法儲存或分享，暫存檔已清理。請確認系統分享功能後重試。', { cause: operationError });
  if (cleanupError) throw new Error('檔案已完成分享，但安全清理暫存檔失敗。請關閉並重新開啟 App 後再繼續匯出。', { cause: cleanupError });
  return { shared: true };
}
