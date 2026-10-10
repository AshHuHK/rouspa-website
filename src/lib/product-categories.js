export function isProductCategoryAvailable(product, categories = []) {
  const category = categories.find(row => row.id === product?.category_id);
  return Boolean(category && category.active !== false && !category.archived_at);
}

// Both the catalogue read and each filter use the same published collection.
// Hidden/out-of-stock products never leave an empty category tab behind.
export function publicProductCatalog(catalog = {}) {
  const allCategories = catalog.categories || [];
  const hideZeroStock = catalog.settings?.zero_stock_behavior === 'hide';
  const products = (catalog.products || []).filter(product =>
    isProductCategoryAvailable(product, allCategories)
    && product.status !== 'draft' && product.status !== 'archived'
    && product.website_visible !== false && product.store_visible !== false
    && (!hideZeroStock || Number(product.inventory) > 0));
  const categories = allCategories.filter(category =>
    category.active !== false && !category.archived_at
    && products.some(product => product.category_id === category.id))
    .sort((a, b) => Number(a.display_order || 0) - Number(b.display_order || 0)
      || String(a.name).localeCompare(String(b.name), 'zh-Hant'));
  return { categories, products };
}
