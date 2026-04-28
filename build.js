#!/usr/bin/env node
/**
 * Build script for Peach Outdoor.
 *
 * Runs at deploy time on Netlify. Reads inventory.json + item-details.html and
 * generates one fully pre-rendered HTML file per inventory item under /inventory/,
 * plus sitemap.xml and robots.txt at the site root.
 *
 * Pre-rendered pages have all SEO content (title, meta description, Open Graph,
 * canonical, JSON-LD Product schema) baked into the HTML before the page is
 * served. The full item data is also embedded as window.__INITIAL_ITEM__ so the
 * existing client-side rendering hydrates instantly without re-fetching.
 *
 * Generated files are NOT committed to git (see .gitignore) — they exist only
 * in the Netlify deploy.
 */

const fs   = require('fs');
const path = require('path');

const ROOT           = __dirname;
const INVENTORY_PATH = path.join(ROOT, 'inventory.json');
const TEMPLATE_PATH  = path.join(ROOT, 'item-details.html');
const OUTPUT_DIR     = path.join(ROOT, 'inventory');
const SITEMAP_PATH   = path.join(ROOT, 'sitemap.xml');
const ROBOTS_PATH    = path.join(ROOT, 'robots.txt');
const SITE_URL       = 'https://peachoutdoor.com';

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

// ─── Per-item SEO computation ────────────────────────────────────────────

function buildSEO(item) {
    const titleBase = [item.Manufacturer, item.Model].filter(Boolean).join(' ');
    const headline  = item.Description || titleBase || 'Item';
    const condition = item.Used ? 'Used' : 'New';

    const priceText = item.Web_Price != null
        ? '$' + Number(item.Web_Price).toLocaleString('en-US', {
            minimumFractionDigits: 2, maximumFractionDigits: 2
        })
        : 'Call for Price';

    const pageTitle = headline + ' — ' + priceText + ' | Peach Outdoor';

    let description;
    if (item.AboutThisItem && item.AboutThisItem.length > 20) {
        description = item.AboutThisItem.replace(/\s+/g, ' ').trim();
        if (description.length > 160) description = description.slice(0, 157).trim() + '…';
    } else {
        description = condition + ' ' + headline + ' for sale at Peach Outdoor in Clanton, AL. ' +
                      priceText + '. Call 205-280-8838.';
    }

    let primaryImage = '';
    if (item.AllPhotos && item.AllPhotos.length) primaryImage = item.AllPhotos[0];
    else if (item.PrimaryPhotoURL)               primaryImage = item.PrimaryPhotoURL;

    const slug      = makeSlug(item);
    const canonical = SITE_URL + '/inventory/' + slug;

    const schema = {
        "@context": "https://schema.org/",
        "@type": "Product",
        "name": headline,
        "description": item.AboutThisItem || (condition + ' ' + headline + ' available at Peach Outdoor'),
        "image": (item.AllPhotos && item.AllPhotos.length
            ? item.AllPhotos
            : (primaryImage ? [primaryImage] : [])),
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
    if (item.Manufacturer) schema.brand        = { "@type": "Brand", "name": item.Manufacturer };
    if (item.Model)        schema.model        = item.Model;
    if (item.SerialNumber) schema.serialNumber = item.SerialNumber;
    if (item.Department)   schema.category     = item.Department;
    if (item.Web_Price != null) schema.offers.price = Number(item.Web_Price);

    return { slug, canonical, pageTitle, description, primaryImage, schema };
}

// ─── HTML rendering ──────────────────────────────────────────────────────

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
        '    <script>window.__INITIAL_ITEM__ = ' + safeJSONForScript(item) + ';</script>'
    ].join('\n');
}

// Replace the original SEO placeholder block with the pre-rendered one.
// The placeholder block runs from the SEO comment to the empty product-schema
// script tag (both were added in the previous SEO commit).
const SEO_BLOCK_RE = /[ \t]*<!-- SEO: dynamically populated by updatePageSEO\(\) once item data loads -->[\s\S]*?<script type="application\/ld\+json" id="product-schema"><\/script>/;

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

function generatePageHtml(template, item) {
    const seo      = buildSEO(item);
    const newBlock = renderHeadBlock(item, seo);

    if (!SEO_BLOCK_RE.test(template)) {
        throw new Error('SEO placeholder block not found in template — has item-details.html drifted?');
    }

    let out = template.replace(SEO_BLOCK_RE, newBlock);
    out     = rewriteRelativePaths(out);
    return { html: out, seo };
}

// ─── Sitemap + robots ────────────────────────────────────────────────────

function buildSitemap(items, slugByItem) {
    const today = new Date().toISOString().slice(0, 10);
    const staticPages = [
        { loc: SITE_URL + '/',                   priority: '1.0', changefreq: 'weekly' },
        { loc: SITE_URL + '/inventory.html',     priority: '0.9', changefreq: 'daily' },
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

    for (const item of items) {
        const slug = slugByItem.get(item);
        if (!slug) continue;
        lines.push('  <url>');
        lines.push('    <loc>' + SITE_URL + '/inventory/' + slug + '</loc>');
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

// ─── Main ────────────────────────────────────────────────────────────────

function main() {
    console.log('[build] Reading ' + INVENTORY_PATH);
    const inventory = JSON.parse(fs.readFileSync(INVENTORY_PATH, 'utf8'));
    console.log('[build] Loaded ' + inventory.length + ' inventory items.');

    console.log('[build] Reading template ' + TEMPLATE_PATH);
    const template = fs.readFileSync(TEMPLATE_PATH, 'utf8');

    if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });

    let written = 0;
    let skipped = 0;
    const slugByItem  = new Map();
    const slugsSeen   = new Map(); // slug -> InventoryID for collision detection

    for (const item of inventory) {
        if (item.InventoryID == null) {
            skipped++;
            continue;
        }
        try {
            const { html, seo } = generatePageHtml(template, item);

            // Defensive: bail if two items somehow produced the same slug.
            // The InventoryID suffix should make this impossible, but let's verify.
            const collision = slugsSeen.get(seo.slug);
            if (collision != null && collision !== item.InventoryID) {
                throw new Error('Slug collision: ' + seo.slug + ' (items ' + collision + ' vs ' + item.InventoryID + ')');
            }
            slugsSeen.set(seo.slug, item.InventoryID);
            slugByItem.set(item, seo.slug);

            const outPath = path.join(OUTPUT_DIR, seo.slug + '.html');
            fs.writeFileSync(outPath, html, 'utf8');
            written++;
        } catch (err) {
            console.error('[build] Failed to render item ' + item.InventoryID + ': ' + err.message);
            skipped++;
        }
    }

    console.log('[build] Wrote ' + written + ' item pages to ' + OUTPUT_DIR + ' (' + skipped + ' skipped).');

    fs.writeFileSync(SITEMAP_PATH, buildSitemap(inventory, slugByItem), 'utf8');
    console.log('[build] Wrote sitemap.xml');

    fs.writeFileSync(ROBOTS_PATH, buildRobots(), 'utf8');
    console.log('[build] Wrote robots.txt');

    console.log('[build] Done.');
}

main();
