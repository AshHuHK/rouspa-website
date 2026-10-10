const productMarks = {
  tea_cake: '茶',
  shampoo_bar: '髮',
  essential_oil: '香',
  tea_bag: '飲',
};

export const serviceDurationCodes = ['duration_45', 'duration_90', 'duration_120'];

function localized(row, field, lang) {
  if (lang === 'en') return row?.[`${field}_en`] || row?.[field] || '';
  return row?.[field] || '';
}

function firstDisplayCharacter(text, fallback = '柔') {
  const value = String(text || '').trim();
  return value.match(/[\p{Script=Han}]/u)?.[0] || value.match(/[A-Za-z0-9]/)?.[0]?.toUpperCase() || fallback;
}

export function serviceMark(text, lang = 'zh') {
  const value = String(text || '').trim();
  if (lang === 'en') return firstDisplayCharacter(value, 'R');
  if (/[清潔淨]/.test(value)) return '清';
  if (/[養護髮]/.test(value)) return '養';
  if (/[薑暖通筋絡]/.test(value)) return '通';
  if (/(按摩|推拿|拳推)/.test(value)) return '按';
  if (/[舒緩鬆]/.test(value)) return '舒';
  return firstDisplayCharacter(value);
}

export function serviceCardVariant(service) {
  return Number(service?.duration_minutes) >= 120 ? 'v120' : 'v90';
}

export function serviceDurationGroups(services = [], categories = [], lang = 'zh') {
  return serviceDurationCodes.map((code, index) => {
    const minutes = Number(code.replace('duration_', ''));
    const category = categories.find(item => item.code === code);
    const items = services.filter(service => service.category_code === code
      || (category?.id && service.category_id === category.id)
      || (!service.category_code && Number(service.duration_minutes) === minutes));
    return {
      code,
      minutes,
      name: localized(category, 'name', lang) || (lang === 'en' ? `${minutes} minutes` : `${minutes} 分鐘`),
      displayOrder: Number(category?.display_order ?? index),
      services: items,
    };
  }).filter(group => group.services.length).sort((a, b) => a.displayOrder - b.displayOrder);
}

export function serviceAddonGroup(addons = [], lang = 'zh') {
  if (!addons.length) return null;
  return {
    code: 'add_on',
    name: lang === 'en' ? 'ADD-ONS' : '加購項目',
    displayOrder: 900,
    services: addons,
  };
}

export function servicePresentationCards(service, lang = 'zh') {
  const configured = service?.website_content?.[lang] || service?.website_content?.zh;
  if (Array.isArray(configured) && configured.length) {
    return configured.map(card => {
      const name = String(card?.name || localized(service, 'name', lang)).trim();
      return {
        stamp: String(card?.stamp || serviceMark(name, lang)).trim().slice(0, 2),
        name,
        sub: String(card?.sub || '').trim(),
        steps: Array.isArray(card?.steps) ? card.steps.map(step => String(step).trim()).filter(Boolean) : [],
      };
    });
  }

  const serviceName = localized(service, 'name', lang);
  const description = localized(service, 'description', lang);
  const minutes = Number(service?.duration_minutes) || 0;
  return [{
    stamp: serviceMark(`${serviceName} ${description}`, lang),
    name: description || serviceName,
    sub: minutes ? (lang === 'en' ? `${minutes}-minute treatment` : `${minutes} 分鐘療程`) : '',
    steps: [],
  }];
}

export function productPresentationMark(product, category, lang = 'zh') {
  if (category?.display_mark) return String(category.display_mark).trim().slice(0, 2);
  if (productMarks[category?.code]) return productMarks[category.code];
  return firstDisplayCharacter(localized(category, 'name', lang) || localized(product, 'name', lang));
}
