import assert from 'node:assert/strict';
import { productPresentationMark, serviceCardVariant, serviceDurationGroups, servicePresentationCards } from '../src/lib/catalog-presentation.js';

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
  { id: 'b', duration_minutes: 60, category_code: 'duration_60' },
  { id: 'c', duration_minutes: 60, category_code: 'duration_60' },
], [
  { id: '45', code: 'duration_45', name: '45 分鐘', display_order: 45 },
  { id: '60', code: 'duration_60', name: '60 分鐘', display_order: 60 },
  { id: '90', code: 'duration_90', name: '90 分鐘', display_order: 90 },
]);
assert.deepEqual(groups.map(group => [group.code, group.services.length]), [['duration_45', 1], ['duration_60', 2]], 'services group into the four fixed durations and empty groups stay hidden');

assert.equal(productPresentationMark({ name: '身體乳' }, { code: 'body_care', name: '身體保養' }), '身', 'new product categories derive a stable artwork mark');
assert.equal(productPresentationMark({ name: '普洱茶' }, { code: 'tea_cake', name: '茶餅' }), '茶', 'known product categories keep their brand mark');

console.log('catalog presentation tests passed');
