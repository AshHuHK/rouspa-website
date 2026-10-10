import assert from 'node:assert/strict';
import { productPresentationMark, serviceAddonGroup, serviceCardVariant, serviceDurationGroups, serviceMenuTitle, servicePresentationCards } from '../src/lib/catalog-presentation.js';

const legacy = servicePresentationCards({
  name: '90分方子',
  duration_minutes: 90,
  website_content: { zh: [{ name: '森呼吸', sub: '柔禾角質調理', steps: ['頭皮洗淨'] }] },
});
assert.equal(legacy[0].stamp, '森', 'configured cards without a stamp receive a stable seal');
assert.deepEqual(legacy[0].steps, ['頭皮洗淨']);

const cleansing = servicePresentationCards({
  name: '45分方子',
  duration_minutes: 45,
  website_content: { zh: [{ name: '苦茶籽潔淨髮浴', steps: ['頭皮洗淨'] }] },
});
assert.equal(cleansing[0].stamp, '清', 'cleansing treatments receive the cleansing seal');

const added = { name: '拳推按摩', description: '按摩項目', duration_minutes: 120, website_content: {} };
const fallback = servicePresentationCards(added);
assert.equal(fallback[0].stamp, '按', 'new services receive a semantic seal');
assert.equal(fallback[0].name, '按摩項目', 'new services use their public description as card copy');
assert.equal(fallback[0].sub, '120 分鐘療程');
assert.equal(serviceCardVariant(added), 'v120');
assert.equal(serviceCardVariant({ duration_minutes: 90 }), 'v90');

const groups = serviceDurationGroups([
  { id: 'a', duration_minutes: 45, category_code: 'duration_45' },
  { id: 'b', duration_minutes: 90, category_code: 'duration_90' },
], [
  { id: '45', code: 'duration_45', name: '45 分鐘', display_order: 45 },
  { id: '90', code: 'duration_90', name: '90 分鐘', display_order: 90 },
  { id: '120', code: 'duration_120', name: '120 分鐘', display_order: 120 },
], 'zh');
assert.deepEqual(groups.map(group => [group.code, group.services.length]), [['duration_45', 1], ['duration_90', 1]], 'main services use the three fixed duration categories');
const addonGroup = serviceAddonGroup([{ id: 'addon', duration_minutes: 60 }], 'zh');
assert.deepEqual([addonGroup.code, addonGroup.name, addonGroup.displayOrder, addonGroup.services.length], ['add_on', '另外項目', 900, 1], 'other services retain the independent fourth group and stable add_on identifier');
assert.equal(serviceAddonGroup([], 'zh'), null, 'the standalone add-on category stays hidden when empty');
assert.equal(serviceAddonGroup([{ id: 'addon' }], 'en').name, 'OTHER SERVICES');

const originalMain = { id: 'main-120', name: '120分全息', name_en: '120-minute Full Care', duration_minutes: 120, price_cents: 320000, category_code: 'duration_120' };
assert.equal(serviceMenuTitle({ name: '45分方子', duration_minutes: 45, category_code: 'duration_45' }), '45分方子');
assert.equal(serviceMenuTitle({ name: '90分方子', duration_minutes: 90, category_code: 'duration_90' }), '90分方子');
assert.equal(serviceMenuTitle(originalMain), '120分方子', 'the original 120-minute main ritual uses the requested menu label');
assert.equal(serviceMenuTitle(originalMain, 'en'), '120-minute Full Care', 'the menu respects the saved English name');
assert.deepEqual(originalMain, { id: 'main-120', name: '120分全息', name_en: '120-minute Full Care', duration_minutes: 120, price_cents: 320000, category_code: 'duration_120' }, 'public headings never change saved service or pricing data');
assert.equal(serviceMenuTitle({ name: '肩頸舒緩', duration_minutes: 45, category_code: 'add_on' }), '肩頸舒緩', 'other services keep their real names even when their duration matches a main ritual');
assert.equal(serviceMenuTitle({ name: '45分舒緩方子', duration_minutes: 45, category_code: 'duration_45' }), '45分舒緩方子', 'later owner edits to a main ritual name remain visible');
assert.equal(serviceMenuTitle({ name: '120分全息', duration_minutes: 120, category_code: 'add_on' }), '120分全息', 'the fallback does not rename unrelated services');

assert.equal(productPresentationMark({ name: '身體乳' }, { code: 'body_care', name: '身體保養' }), '身', 'new product categories derive a stable artwork mark');
assert.equal(productPresentationMark({ name: '普洱茶' }, { code: 'tea_cake', name: '茶餅' }), '茶', 'known product categories keep their brand mark');

console.log('catalog presentation tests passed');
