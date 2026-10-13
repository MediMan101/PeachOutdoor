#!/usr/bin/env node
/**
 * Build script for Peach Outdoor.
 *
 * Runs at deploy time on Netlify. Reads inventory.json + specs.json +
 * item-details.html and generates one fully pre-rendered HTML file per
 * inventory item under /inventory/, plus a crawlable browse index at
 * /inventory/index.html, sitemap.xml and robots.txt at the site root.
 *
 * Pre-rendered pages have both the SEO head (title, meta description, Open
 * Graph, canonical, JSON-LD Product + BreadcrumbList schema) AND the visible
 * item content (headline, price, specs, photos) baked into the HTML before the
 * page is served. The body matters as much as the head: Googlebot renders
 * JavaScript only on a deferred second pass, and most AI crawlers (GPTBot,
 * ClaudeBot, PerplexityBot) do not execute JavaScript at all — to them a
 * client-rendered page is a blank page.
 *
 * The full item data is also embedded as window.__INITIAL_ITEM__ so the
 * existing client-side rendering hydrates instantly without re-fetching. The
 * runtime render replaces #content with markup identical to what is baked in
 * here, so the swap is invisible; keep renderItemBody() below in sync with
 * displayItem() in item-details.html.
 *
 * Breadcrumb and related-item links are emitted OUTSIDE #content so they
 * survive that runtime replacement — they are real links for real visitors,
 * not crawler-only decoration.
 *
 * Generated files are NOT committed to git (see .gitignore) — they exist only
 * in the Netlify deploy.
 */

const fs   = require('fs');
const path = require('path');

const ROOT           = __dirname;
const INVENTORY_PATH = path.join(ROOT, 'inventory.json');
const SPECS_PATH     = path.join(ROOT, 'specs.json');
const TEMPLATE_PATH  = path.join(ROOT, 'item-details.html');
const OUTPUT_DIR     = path.join(ROOT, 'inventory');
const SITEMAP_PATH   = path.join(ROOT, 'sitemap.xml');
const ROBOTS_PATH    = path.join(ROOT, 'robots.txt');
const SITE_URL       = 'https://peachoutdoor.com';

// og:image for the 850-odd items that have no photo yet. An empty content=""
// gives a broken share card; the logo at least shows who the link is from.
// Matches what index.html uses for the homepage.
const FALLBACK_OG_IMAGE = SITE_URL + '/PeachOutdoorLogo.png';

// How many "more from this brand" links to place on each item page.
const RELATED_LIMIT = 8;

// ─── Slug + escape helpers ────────────────────────────────────────────────

function makeSlug(item) {
    const base = item.Description
        || [item.Manufacturer, item.Model].filter(Boolean).join(' ')
        || 'item';
    let slug = base
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '');
    if (slug.length > 60) slug = slug.slice(0, 60).replace(/-+$/, '');
    return slug + '-' + item.InventoryID;
}

// Anchor id for a manufacturer section on the browse page.
function makeGroupSlug(name) {
    return String(name || 'other')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '') || 'other';
}

function escapeHtml(s) {
    return String(s == null ? '' : s)
        .replace(/&/g,  '&amp;')
        .replace(/"/g,  '&quot;')
        .replace(/'/g,  '&#39;')
        .replace(/</g,  '&lt;')
        .replace(/>/g,  '&gt;');
}

// JSON.stringify is unsafe in <script> tags because "</script>" inside a string
// would close the script element early. Escape "<" so the embedded JSON cannot
// terminate the script block.
function safeJSONForScript(value) {
    return JSON.stringify(value).replace(/</g, '\\u003c');
}

function formatMoney(n) {
    return '$' + Number(n).toLocaleString('en-US', {
        minimumFractionDigits: 2, maximumFractionDigits: 2
    });
}

// ─── Per-item SEO computation ────────────────────────────────────────────

function buildSEO(item) {
    const titleBase = [item.Manufacturer, item.Model].filter(Boolean).join(' ');
    const headline  = item.Description || titleBase || 'Item';
    const condition = item.Used ? 'Used' : 'New';

    const priceText = (item.PriceDisplayMode === 'MonthlyPayment' && item.PriceDisplayText)
        ? item.PriceDisplayText // e.g. "$249 per month (WAC)"
        : (item.Web_Price != null
            ? formatMoney(item.Web_Price)
            : 'Call for Price');

    const pageTitle = headline + ' — ' + priceText + ' | Peach Outdoor';

    let description;
    if (item.AboutThisItem && item.AboutThisItem.length > 20) {
        description = item.AboutThisItem.replace(/\s+/g, ' ').trim();
        if (description.length > 160) description = description.slice(0, 157).trim() + '…';
    } else {
        description = condition + ' ' + headline + ' for sale at Peach Outdoor in Clanton, AL. ' +
                      priceText + '. Call 205-280-8838.';
    }

    // photosFor() normalises AllPhotos' three possible JSON shapes — see its
    // definition. Never index into item.AllPhotos directly.
    const photos       = photosFor(item);
    const primaryImage = photos.length ? photos[0] : FALLBACK_OG_IMAGE;

    const slug      = makeSlug(item);
    const canonical = SITE_URL + '/inventory/' + slug;

    const schema = {
        "@context": "https://schema.org/",
        "@type": "Product",
        "name": headline,
        "description": item.AboutThisItem || (condition + ' ' + headline + ' available at Peach Outdoor'),
        // Omitted entirely when the item has no photo — an empty array is a
        // validation warning on Product, a missing key is just incomplete.
        "sku": String(item.InventoryID || ''),
        "itemCondition": item.Used
            ? "https://schema.org/UsedCondition"
            : "https://schema.org/NewCondition",
        "offers": {
            "@type": "Offer",
            "url": canonical,
            "priceCurrency": "USD",
            "availability": "https://schema.org/InStock",
            "seller": {
                "@type": "AutoDealer",
                "name": "Peach Outdoor",
                "telephone": "+1-205-280-8838",
                "address": {
                    "@type": "PostalAddress",
                    "streetAddress": "1940 Big M Blvd",
                    "addressLocality": "Clanton",
                    "addressRegion": "AL",
                    "postalCode": "35046",
                    "addressCountry": "US"
                }
            }
        }
    };
    if (photos.length)     schema.image        = photos;
    if (item.Manufacturer) schema.brand        = { "@type": "Brand", "name": item.Manufacturer };
    if (item.Model)        schema.model        = item.Model;
    if (item.SerialNumber) schema.serialNumber = item.SerialNumber;
    if (item.Department)   schema.category     = item.Department;
    if (item.Web_Price != null) schema.offers.price = Number(item.Web_Price);

    return { slug, canonical, pageTitle, description, primaryImage, headline, priceText, schema };
}

// Breadcrumb trail: Home > Inventory > Manufacturer > this item.
function buildBreadcrumbSchema(item, seo) {
    const trail = [
        { name: 'Home',      url: SITE_URL + '/' },
        { name: 'Inventory', url: SITE_URL + '/inventory/' }
    ];
    if (item.Manufacturer) {
        trail.push({
            name: item.Manufacturer,
            url:  SITE_URL + '/inventory/#' + makeGroupSlug(item.Manufacturer)
        });
    }
    trail.push({ name: seo.headline, url: seo.canonical });

    return {
        "@context": "https://schema.org",
        "@type": "BreadcrumbList",
        "itemListElement": trail.map((t, i) => ({
            "@type": "ListItem",
            "position": i + 1,
            "name": t.name,
            "item": t.url
        }))
    };
}

// ─── Body pre-rendering ──────────────────────────────────────────────────
// Mirrors displayItem() / renderGallery() / renderSpecs() in item-details.html.
// Everything is escaped here because this markup is written straight to disk;
// the runtime path builds the same strings from live data via innerHTML.

function renderPrice(item) {
    let priceHtml    = '';
    let priceSubHtml = '';

    if (item.PriceDisplayMode === 'MonthlyPayment' && item.PriceDisplayText) {
        priceHtml = '<span class="price-monthly">' + escapeHtml(item.PriceDisplayText) + '</span>';
        priceSubHtml = '<div class="price-monthly-details">' +
            escapeHtml(item.PriceDisplaySubText || 'See dealer for details') + '</div>';
    } else if (item.Web_Price != null) {
        priceHtml = '<span class="price-main">' + escapeHtml(formatMoney(item.Web_Price)) + '</span>';
        if (item.MSRP && item.MSRP > item.Web_Price) {
            priceHtml += '<span class="msrp-price">MSRP ' + escapeHtml(formatMoney(item.MSRP)) + '</span>';
        }
    } else {
        priceHtml = '<span class="price-call">Call for Price</span>';
    }

    return { priceHtml, priceSubHtml };
}

function renderPill(label, value) {
    return '<div class="pill"><span class="pill-label">' + escapeHtml(label) +
           '</span><span class="pill-value">' + escapeHtml(value) + '</span></div>';
}

function renderPills(item) {
    let html = '';
    if (item.Department) html += renderPill('Type', item.Department);
    if (item.Used && item.Hours != null) html += renderPill('Hours', Number(item.Hours).toLocaleString('en-US'));
    if (item.Year)       html += renderPill('Year', item.Year);
    return html;
}

function renderGallery(photos, modelName) {
    if (!photos.length) {
        return '<div class="main-photo-wrap"><div class="placeholder-icon">&#128668;</div></div>';
    }

    const alt = escapeHtml(modelName || 'Peach Outdoor equipment');

    // The first photo is the LCP element on this page: load it eagerly and let
    // the browser prioritise it. Thumbnails are below the fold — lazy.
    let mainHtml =
        '<div class="main-photo-wrap" id="mainPhotoWrap">' +
            '<img id="mainPhotoImg" src="' + escapeHtml(photos[0]) + '" alt="' + alt + '"' +
                ' loading="eager" fetchpriority="high" decoding="async">' +
            (photos.length > 1
                ? '<button class="photo-nav prev" onclick="changePhoto(-1)">&#8249;</button>' +
                  '<button class="photo-nav next" onclick="changePhoto(1)">&#8250;</button>' +
                  '<div class="photo-counter" id="photoCounter">1 / ' + photos.length + '</div>'
                : '') +
        '</div>';

    if (photos.length === 1) return mainHtml;

    let thumbsHtml = '<div class="thumbnails-row" id="thumbsRow">';
    for (let i = 0; i < photos.length; i++) {
        const full = escapeHtml(photos[i]);
        thumbsHtml += '<div class="thumb' + (i === 0 ? ' active' : '') + '" onclick="selectPhoto(' + i + ')">' +
            '<img src="' + escapeHtml(photoVariant(photos[i], 400)) + '" data-full="' + full + '"' +
                ' alt="' + alt + ' photo ' + (i + 1) + '"' +
                ' loading="lazy" decoding="async"' +
                ' onerror="this.onerror=null;this.src=this.dataset.full">' +
            '</div>';
    }
    thumbsHtml += '</div>';
    return mainHtml + thumbsHtml;
}

function renderSpecs(specs) {
    let html = '<div class="specs-grid">';
    for (const [category, items] of Object.entries(specs)) {
        html += '<div class="spec-category"><div class="spec-category-header">' +
                escapeHtml(category) + '</div>';
        for (const [label, value] of Object.entries(items)) {
            html += '<div class="spec-item"><span class="spec-label">' + escapeHtml(label) +
                    '</span><span class="spec-value">' + escapeHtml(value) + '</span></div>';
        }
        html += '</div>';
    }
    return html + '</div>';
}

function renderNoSpecs() {
    return '<div class="no-specs"><h3>Specifications Coming Soon</h3>' +
           '<p>Detailed specs for this model are being updated. Contact us for more information.</p></div>';
}

// Sync-Inventory.ps1 uploads <name>_400.jpg / <name>_800.jpg next to every
// Bunny-hosted photo. Mirrors photoVariant() in item-details.html — keep them
// in sync. Only Bunny .jpg URLs have derivatives; legacy Cloudinary URLs and
// anything else pass through unchanged.
function photoVariant(url, width) {
    if (typeof url !== 'string' || !width) return url;
    if (url.indexOf('peachoutdoor.b-cdn.net/') === -1) return url;
    return url.replace(/\.jpg$/i, '_' + width + '.jpg');
}

// AllPhotos has historically arrived in three different JSON shapes, because
// PowerShell's pipeline unrolled the array before ConvertTo-Json saw it:
//   two or more photos -> ["url", "url"]   (an array, as intended)
//   exactly one photo  -> "url"            (a bare string)
//   no photos          -> {}               (an empty object)
// Reading AllPhotos[0] off the string form yields "h", which is how og:image
// ended up as a single character on every single-photo page. Sync-Inventory.ps1
// now always emits an array, but a deployed inventory.json can still predate
// that, so normalise every shape here rather than trusting the input.
function photosFor(item) {
    const raw = item.AllPhotos;
    let photos = [];

    if (Array.isArray(raw))           photos = raw.filter(u => typeof u === 'string' && u);
    else if (typeof raw === 'string' && raw) photos = [raw];

    if (!photos.length && item.PrimaryPhotoURL) photos = [item.PrimaryPhotoURL];
    if (!photos.length && item.ImageURL)        photos = [item.ImageURL];
    return photos;
}

function renderItemBody(item, specs) {
    const { priceHtml, priceSubHtml } = renderPrice(item);
    const pillsHtml = renderPills(item);
    const photos    = photosFor(item);

    return '<div class="product-layout">' +
            '<div class="gallery-col">' + renderGallery(photos, item.Model) + '</div>' +
            '<div class="info-col"><div class="info-panel">' +
                '<div class="item-manufacturer">' + escapeHtml(item.Manufacturer || '') + '</div>' +
                (item.Description
                    ? '<h1 class="item-description-title">' + escapeHtml(item.Description) + '</h1>'
                    : '') +
                '<div class="item-title">' + escapeHtml(item.Model || 'Model N/A') + '</div>' +
                (item.Series ? '<div class="item-series">' + escapeHtml(item.Series) + ' Series</div>' : '') +
                '<div class="item-serial">S/N: ' + escapeHtml(item.SerialNumber || 'N/A') + '</div>' +
                '<div class="price-row">' + priceHtml +
                    '<span class="badge ' + (item.Used ? 'badge-used' : 'badge-new') + '">' +
                        (item.Used ? 'USED' : 'NEW') +
                    '</span>' +
                '</div>' + priceSubHtml +
                (pillsHtml ? '<div class="info-pills">' + pillsHtml + '</div>' : '') +
                (item.Notes
                    ? '<div class="notes-box">&#128205; ' + escapeHtml(item.Notes) + '</div>'
                    : '') +
                (item.AboutThisItem
                    ? '<div class="about-this-item"><div class="about-this-item-title">About This Item</div>' +
                      '<div class="about-this-item-body">' + escapeHtml(item.AboutThisItem) + '</div></div>'
                    : '') +
                '<hr class="divider">' +
                '<button class="btn-quote" onclick="openInquiryModal()">&#128203; Get A Quote</button>' +
                '<button class="btn-chat" onclick="chatAboutItem()">&#128172; Chat About This Item</button>' +
                '<button class="btn-back" onclick="goBackToInventory()">&#8592; Browse More Items</button>' +
            '</div></div>' +
        '</div>' +
        '<div class="specs-section">' +
            '<div class="specs-section-title">Specifications</div>' +
            (specs ? renderSpecs(specs) : renderNoSpecs()) +
        '</div>';
}

// ─── Breadcrumb + related links (outside #content, so they persist) ───────

function renderBreadcrumb(item, seo) {
    const parts = [
        '<a href="/">Home</a>',
        '<a href="/inventory/">Inventory</a>'
    ];
    if (item.Manufacturer) {
        parts.push('<a href="/inventory/#' + escapeHtml(makeGroupSlug(item.Manufacturer)) + '">' +
                   escapeHtml(item.Manufacturer) + '</a>');
    }
    parts.push('<span aria-current="page">' + escapeHtml(seo.headline) + '</span>');

    return '<nav class="crumbs" aria-label="Breadcrumb">' +
           parts.join('<span class="crumb-sep">&#8250;</span>') +
           '</nav>';
}

function renderRelated(item, related) {
    if (!related.length) return '';

    const heading = item.Manufacturer
        ? 'More ' + escapeHtml(item.Manufacturer) + ' equipment in stock'
        : 'More equipment in stock';

    const links = related.map(r =>
        '<li><a href="/inventory/' + escapeHtml(r.slug) + '">' +
        escapeHtml(r.headline) +
        '<span class="related-price">' + escapeHtml(r.priceText) + '</span>' +
        '</a></li>'
    ).join('');

    return '<section class="related-block">' +
                '<h2 class="related-title">' + heading + '</h2>' +
                '<ul class="related-list">' + links + '</ul>' +
                '<a class="related-all" href="/inventory/">Browse all Peach Outdoor inventory &#8594;</a>' +
           '</section>';
}

// ─── HTML assembly ───────────────────────────────────────────────────────

function renderHeadBlock(item, seo) {
    return [
        '    <!-- SEO: pre-rendered at build time. JS keeps these in sync at runtime. -->',
        '    <title id="page-title">' + escapeHtml(seo.pageTitle) + '</title>',
        '    <meta id="meta-description" name="description" content="' + escapeHtml(seo.description) + '">',
        '    <meta property="og:type" content="product">',
        '    <meta property="og:title" id="og-title" content="' + escapeHtml(seo.pageTitle) + '">',
        '    <meta property="og:description" id="og-description" content="' + escapeHtml(seo.description) + '">',
        '    <meta property="og:image" id="og-image" content="' + escapeHtml(seo.primaryImage) + '">',
        '    <meta property="og:url" id="og-url" content="' + escapeHtml(seo.canonical) + '">',
        '    <meta name="twitter:card" content="summary_large_image">',
        '    <link rel="canonical" id="canonical-url" href="' + escapeHtml(seo.canonical) + '">',
        '    <script type="application/ld+json" id="product-schema">' + safeJSONForScript(seo.schema) + '</script>',
        '    <script type="application/ld+json" id="breadcrumb-schema">' +
            safeJSONForScript(buildBreadcrumbSchema(item, seo)) + '</script>',
        '    <script>window.__INITIAL_ITEM__ = ' + safeJSONForScript(item) + ';</script>'
    ].join('\n');
}

// Replace the original SEO placeholder block with the pre-rendered one.
// The placeholder block runs from the SEO comment to the empty product-schema
// script tag (both were added in the previous SEO commit).
const SEO_BLOCK_RE = /[ \t]*<!-- SEO: dynamically populated by updatePageSEO\(\) once item data loads -->[\s\S]*?<script type="application\/ld\+json" id="product-schema"><\/script>/;

// The empty shell the client-side renderer fills in. Pre-rendering swaps this
// for the real markup, wrapped in breadcrumb + related links.
const CONTENT_BLOCK_RE = /<div id="content">\s*<div class="loading">[\s\S]*?<\/div>\s*<\/div>/;

// Rewrite relative paths in the template so they still resolve when the
// generated file lives in /inventory/ rather than the site root.
function rewriteRelativePaths(html) {
    return html
        .replace(/href="index\.html"/g,             'href="/index.html"')
        .replace(/href="inventory\.html"/g,         'href="/inventory.html"')
        .replace(/src="PeachOutdoorLogo\.png"/g,    'src="/PeachOutdoorLogo.png"')
        .replace(/fetch\('inventory\.json'\)/g,     "fetch('/inventory.json')")
        .replace(/fetch\('specs\.json'\)/g,         "fetch('/specs.json')")
        .replace(/window\.location\.href = 'index\.html'/g,    "window.location.href = '/index.html'")
        .replace(/window\.location\.href = 'inventory\.html'/g, "window.location.href = '/inventory.html'");
}

function generatePageHtml(template, item, seo, specs, related) {
    if (!SEO_BLOCK_RE.test(template)) {
        throw new Error('SEO placeholder block not found in template — has item-details.html drifted?');
    }
    if (!CONTENT_BLOCK_RE.test(template)) {
        throw new Error('#content placeholder not found in template — has item-details.html drifted?');
    }

    const bodyBlock =
        renderBreadcrumb(item, seo) +
        '\n    <div id="content">' + renderItemBody(item, specs) + '</div>\n    ' +
        renderRelated(item, related);

    let out = template.replace(SEO_BLOCK_RE, renderHeadBlock(item, seo));
    out     = out.replace(CONTENT_BLOCK_RE, bodyBlock);
    out     = rewriteRelativePaths(out);
    return out;
}

// ─── Browse index: /inventory/ ───────────────────────────────────────────
// A plain, crawlable directory of every item, grouped by manufacturer. This is
// the page that gives all ~1,000 item URLs an internal link; before it existed
// the sitemap was their only discovery path and no link equity reached them.

function buildBrowsePage(entries) {
    const byMfg = new Map();
    for (const e of entries) {
        const key = e.item.Manufacturer || 'Other Equipment';
        if (!byMfg.has(key)) byMfg.set(key, []);
        byMfg.get(key).push(e);
    }

    const mfgNames = [...byMfg.keys()].sort((a, b) => a.localeCompare(b));

    const title = 'All Inventory — Tractors, Mowers, UTVs & Attachments | Peach Outdoor';
    const desc  = 'Browse all ' + entries.length + ' items in stock at Peach Outdoor in Clanton, Alabama — ' +
                  mfgNames.slice(0, 6).join(', ') + ' and more. Call 205-280-8838.';

    const jumpLinks = mfgNames.map(m =>
        '<a class="jump" href="#' + escapeHtml(makeGroupSlug(m)) + '">' + escapeHtml(m) +
        ' <span>(' + byMfg.get(m).length + ')</span></a>'
    ).join('');

    const sections = mfgNames.map(m => {
        const group = byMfg.get(m).sort((a, b) => a.seo.headline.localeCompare(b.seo.headline));
        const rows  = group.map(e =>
            '<li><a href="/inventory/' + escapeHtml(e.seo.slug) + '">' +
                '<span class="bi-name">' + escapeHtml(e.seo.headline) + '</span>' +
                '<span class="bi-meta">' +
                    (e.item.Used ? 'Used' : 'New') +
                    (e.item.Department ? ' &middot; ' + escapeHtml(e.item.Department) : '') +
                '</span>' +
                '<span class="bi-price">' + escapeHtml(e.seo.priceText) + '</span>' +
            '</a></li>'
        ).join('');

        return '<section class="brand-block" id="' + escapeHtml(makeGroupSlug(m)) + '">' +
                    '<h2>' + escapeHtml(m) + ' <span class="count">' + group.length + ' in stock</span></h2>' +
                    '<ul class="browse-list">' + rows + '</ul>' +
               '</section>';
    }).join('\n');

    const itemListSchema = {
        "@context": "https://schema.org",
        "@type": "CollectionPage",
        "name": "Peach Outdoor Inventory",
        "description": desc,
        "url": SITE_URL + '/inventory/',
        "isPartOf": { "@type": "WebSite", "name": "Peach Outdoor", "url": SITE_URL + '/' }
    };

    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${escapeHtml(title)}</title>
    <meta name="description" content="${escapeHtml(desc)}">
    <link rel="canonical" href="${SITE_URL}/inventory/">
    <meta property="og:type" content="website">
    <meta property="og:title" content="${escapeHtml(title)}">
    <meta property="og:description" content="${escapeHtml(desc)}">
    <meta property="og:url" content="${SITE_URL}/inventory/">
    <script type="application/ld+json">${safeJSONForScript(itemListSchema)}</script>
    <style>
        :root {
            --charcoal-dark:  #1f1f21;
            --charcoal-mid:   #2c2c2e;
            --charcoal-border:#4a4a4c;
            --accent:         #e07b2a;
            --text-primary:   #f0f0f0;
            --text-secondary: #a0a0a4;
            --text-muted:     #707074;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--charcoal-dark);
            color: var(--text-primary);
            min-height: 100vh;
        }
        .top-bar {
            background: var(--charcoal-mid);
            border-bottom: 1px solid var(--charcoal-border);
            padding: 14px 32px;
            display: flex; align-items: center; justify-content: space-between;
            position: sticky; top: 0; z-index: 100;
        }
        .top-bar a { color: var(--accent); text-decoration: none; font-weight: 600; }
        .top-bar img { height: 42px; width: auto; }
        .wrap { max-width: 1200px; margin: 0 auto; padding: 28px 20px 60px; }
        h1 { font-size: 1.7em; margin-bottom: 6px; }
        .lede { color: var(--text-secondary); margin-bottom: 22px; font-size: 0.95em; }
        .jumps { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 32px; }
        .jump {
            background: var(--charcoal-mid); border: 1px solid var(--charcoal-border);
            border-radius: 999px; padding: 6px 14px; font-size: 0.85em;
            color: var(--text-primary); text-decoration: none;
        }
        .jump span { color: var(--text-muted); }
        .jump:hover { border-color: var(--accent); color: var(--accent); }
        .brand-block { margin-bottom: 36px; scroll-margin-top: 80px; }
        .brand-block h2 {
            font-size: 1.15em; padding-bottom: 8px; margin-bottom: 10px;
            border-bottom: 1px solid var(--charcoal-border);
        }
        .brand-block h2 .count { color: var(--text-muted); font-size: 0.72em; font-weight: 400; }
        .browse-list { list-style: none; }
        .browse-list li { border-bottom: 1px solid #333; }
        .browse-list a {
            display: flex; gap: 14px; align-items: baseline; flex-wrap: wrap;
            padding: 9px 4px; color: var(--text-primary); text-decoration: none;
        }
        .browse-list a:hover { background: var(--charcoal-mid); color: var(--accent); }
        .bi-name { flex: 1 1 320px; }
        .bi-meta { color: var(--text-muted); font-size: 0.82em; }
        .bi-price { color: var(--accent); font-weight: 600; font-size: 0.9em; }
        @media (max-width: 600px) {
            .top-bar { padding: 12px 16px; }
            .wrap { padding: 20px 16px 48px; }
        }
    </style>
</head>
<body>
    <div class="top-bar">
        <a href="/">&#8592; Peach Outdoor Home</a>
        <a href="/inventory.html">Search &amp; filter inventory</a>
    </div>
    <div class="wrap">
        <h1>All Inventory at Peach Outdoor</h1>
        <p class="lede">
            ${entries.length} items in stock in Clanton, Alabama. Sales 205-280-8838 &middot;
            1940 Big M Blvd, Clanton, AL 35046. Prefer to filter by type, price or condition?
            Use the <a href="/inventory.html" style="color:var(--accent)">inventory search</a>.
        </p>
        <div class="jumps">${jumpLinks}</div>
${sections}
    </div>
</body>
</html>
`;
}

// ─── Sitemap + robots ────────────────────────────────────────────────────

function buildSitemap(entries) {
    const today = new Date().toISOString().slice(0, 10);
    const staticPages = [
        { loc: SITE_URL + '/',                   priority: '1.0', changefreq: 'weekly' },
        { loc: SITE_URL + '/inventory.html',     priority: '0.9', changefreq: 'daily' },
        { loc: SITE_URL + '/inventory/',         priority: '0.9', changefreq: 'daily' },
        { loc: SITE_URL + '/financing.html',     priority: '0.5', changefreq: 'monthly' },
        { loc: SITE_URL + '/about.html',         priority: '0.5', changefreq: 'monthly' },
        { loc: SITE_URL + '/configurator.html',  priority: '0.5', changefreq: 'monthly' }
    ];

    const lines = [];
    lines.push('<?xml version="1.0" encoding="UTF-8"?>');
    lines.push('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">');

    for (const page of staticPages) {
        lines.push('  <url>');
        lines.push('    <loc>' + page.loc + '</loc>');
        lines.push('    <lastmod>' + today + '</lastmod>');
        lines.push('    <changefreq>' + page.changefreq + '</changefreq>');
        lines.push('    <priority>' + page.priority + '</priority>');
        lines.push('  </url>');
    }

    for (const e of entries) {
        lines.push('  <url>');
        lines.push('    <loc>' + SITE_URL + '/inventory/' + e.seo.slug + '</loc>');
        lines.push('    <lastmod>' + today + '</lastmod>');
        lines.push('    <changefreq>weekly</changefreq>');
        lines.push('    <priority>0.7</priority>');
        lines.push('  </url>');
    }

    lines.push('</urlset>');
    return lines.join('\n') + '\n';
}

function buildRobots() {
    return [
        'User-agent: *',
        'Allow: /',
        'Disallow: /.netlify/',
        '',
        'Sitemap: ' + SITE_URL + '/sitemap.xml',
        ''
    ].join('\n');
}

// ─── Specs lookup ────────────────────────────────────────────────────────

function loadSpecsIndex() {
    if (!fs.existsSync(SPECS_PATH)) {
        console.warn('[build] specs.json not found — item pages will render without spec tables.');
        return new Map();
    }
    try {
        const specs = JSON.parse(fs.readFileSync(SPECS_PATH, 'utf8'));
        const index = new Map();
        for (const s of specs) {
            if (s && s.Model != null && s.Specs) index.set(String(s.Model), s.Specs);
        }
        console.log('[build] Loaded ' + index.size + ' model spec sets.');
        return index;
    } catch (err) {
        console.warn('[build] Could not parse specs.json (' + err.message + ') — continuing without specs.');
        return new Map();
    }
}

// Mirrors the runtime lookup: SpecModel wins, else Model.
function specsForItem(item, index) {
    return index.get(String(item.SpecModel || item.Model)) || null;
}

// ─── Related items ───────────────────────────────────────────────────────
// Same manufacturer, same department first, then any same-manufacturer item.

function pickRelated(entry, byManufacturer) {
    const pool = byManufacturer.get(entry.item.Manufacturer || '') || [];
    const others = pool.filter(e => e.item.InventoryID !== entry.item.InventoryID);

    const sameDept = others.filter(e => e.item.Department && e.item.Department === entry.item.Department);
    const rest     = others.filter(e => !sameDept.includes(e));

    return [...sameDept, ...rest].slice(0, RELATED_LIMIT).map(e => ({
        slug:      e.seo.slug,
        headline:  e.seo.headline,
        priceText: e.seo.priceText
    }));
}

// ─── Main ────────────────────────────────────────────────────────────────

function main() {
    console.log('[build] Reading ' + INVENTORY_PATH);
    const inventory = JSON.parse(fs.readFileSync(INVENTORY_PATH, 'utf8'));
    console.log('[build] Loaded ' + inventory.length + ' inventory items.');

    const specsIndex = loadSpecsIndex();

    console.log('[build] Reading template ' + TEMPLATE_PATH);
    const template = fs.readFileSync(TEMPLATE_PATH, 'utf8');

    if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });

    // ── Pass 1: compute SEO + slug for every item, detecting collisions.
    // Related-item links need every slug resolved before any page is written.
    const entries   = [];
    const slugsSeen = new Map(); // slug -> InventoryID
    let skipped     = 0;

    for (const item of inventory) {
        if (item.InventoryID == null) { skipped++; continue; }
        try {
            const seo = buildSEO(item);

            // Defensive: bail if two items somehow produced the same slug.
            // The InventoryID suffix should make this impossible, but let's verify.
            const collision = slugsSeen.get(seo.slug);
            if (collision != null && collision !== item.InventoryID) {
                throw new Error('Slug collision: ' + seo.slug +
                                ' (items ' + collision + ' vs ' + item.InventoryID + ')');
            }
            slugsSeen.set(seo.slug, item.InventoryID);
            entries.push({ item, seo });
        } catch (err) {
            console.error('[build] Failed to prepare item ' + item.InventoryID + ': ' + err.message);
            skipped++;
        }
    }

    const byManufacturer = new Map();
    for (const e of entries) {
        const key = e.item.Manufacturer || '';
        if (!byManufacturer.has(key)) byManufacturer.set(key, []);
        byManufacturer.get(key).push(e);
    }

    // ── Pass 2: render and write each page.
    let written   = 0;
    let withSpecs = 0;

    for (const entry of entries) {
        try {
            const specs   = specsForItem(entry.item, specsIndex);
            const related = pickRelated(entry, byManufacturer);
            const html    = generatePageHtml(template, entry.item, entry.seo, specs, related);

            fs.writeFileSync(path.join(OUTPUT_DIR, entry.seo.slug + '.html'), html, 'utf8');
            written++;
            if (specs) withSpecs++;
        } catch (err) {
            console.error('[build] Failed to render item ' + entry.item.InventoryID + ': ' + err.message);
            skipped++;
        }
    }

    console.log('[build] Wrote ' + written + ' item pages to ' + OUTPUT_DIR +
                ' (' + withSpecs + ' with spec tables, ' + skipped + ' skipped).');

    fs.writeFileSync(path.join(OUTPUT_DIR, 'index.html'), buildBrowsePage(entries), 'utf8');
    console.log('[build] Wrote inventory/index.html (browse index, ' + entries.length + ' links)');

    fs.writeFileSync(SITEMAP_PATH, buildSitemap(entries), 'utf8');
    console.log('[build] Wrote sitemap.xml');

    fs.writeFileSync(ROBOTS_PATH, buildRobots(), 'utf8');
    console.log('[build] Wrote robots.txt');

    console.log('[build] Done.');
}

main();
