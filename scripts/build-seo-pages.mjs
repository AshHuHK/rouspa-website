import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const template = await readFile(resolve(root, 'index.html'), 'utf8');
const home = {
  title: '柔療髮浴 ROU SPA｜嘉義東方頭療・經絡舒緩',
  description: '柔療髮浴 ROU SPA 位於嘉義市西區蘭井街421號，提供東方頭療、經絡舒緩與養生髮浴。查看療程、技師與營業資訊，立即線上預約。',
  socialDescription: '嘉義東方頭療、經絡舒緩與養生髮浴；查看療程、技師與營業資訊，立即線上預約。',
  canonical: 'https://www.rouspa.tw/',
};

const pages = {
  shop: {
    title: '柔療好物選｜柔療髮浴 ROU SPA 嘉義',
    description: '瀏覽柔療髮浴門店精選養生、頭皮與居家保養商品；價格、分類與門店庫存即時更新。',
    canonical: 'https://www.rouspa.tw/shop/',
  },
  contact: {
    title: '聯繫柔療髮浴｜嘉義頭療預約與門店資訊',
    description: '柔療髮浴 ROU SPA 位於嘉義市西區蘭井街421號。查看電話、LINE、營業時間與交通資訊。',
    canonical: 'https://www.rouspa.tw/contact/',
  },
};

function pageHtml(page) {
  return template
    .replace(`<title>${home.title}</title>`, `<title>${page.title}</title>`)
    .replace(`content="${home.description}"`, `content="${page.description}"`)
    .replace(`href="${home.canonical}"`, `href="${page.canonical}"`)
    .replace(`property="og:title" content="${home.title}"`, `property="og:title" content="${page.title}"`)
    .replace(`property="og:description" content="${home.socialDescription}"`, `property="og:description" content="${page.description}"`)
    .replace(`property="og:url" content="${home.canonical}"`, `property="og:url" content="${page.canonical}"`)
    .replace(`name="twitter:title" content="${home.title}"`, `name="twitter:title" content="${page.title}"`)
    .replace(`name="twitter:description" content="${home.socialDescription}"`, `name="twitter:description" content="${page.description}"`);
}

for (const [directory, page] of Object.entries(pages)) {
  const output = resolve(root, directory, 'index.html');
  await mkdir(resolve(root, directory), { recursive: true });
  await writeFile(output, pageHtml(page));
}
