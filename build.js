#!/usr/bin/env node
/**
 * Build script for Peach Outdoor.
 *
 * Runs at deploy time on Netlify. Reads inventory.json + specs.json +
 * item-details.html and generates one fully pre-rendered HTML file per
 * inventory item under /inventory/, plus a crawlable browse index at
 * /inventory/browse, sitemap.xml and robots.txt at the site root.
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

// The crawlable browse index cannot live at /inventory/. Netlify resolves
// /inventory to the inventory.html FILE in preference to the inventory/
// directory's index, and strips the trailing slash first, so /inventory/
// 301s to /inventory and lands on the search page. /inventory/browse has no
// such collision — it resolves to inventory/browse.html exactly the way the
// ~1,000 generated /inventory/<slug> pages already do.
const BROWSE_FILE = 'browse.html';
const BROWSE_PATH = '/inventory/' + BROWSE_FILE.replace(/\.html$/, '');

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
            : (item.MSRP > 0 ? 'MSRP ' + formatMoney(item.MSRP) : 'Call for Price'));

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
                "@type": "Store",
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
    else if (item.MSRP > 0) schema.offers.price = Number(item.MSRP); // shown on the page as "MSRP $X, call for this month's discounted price"

    return { slug, canonical, pageTitle, description, primaryImage, headline, priceText, schema };
}

// Breadcrumb trail: Home > Inventory > Manufacturer > this item.
function buildBreadcrumbSchema(item, seo) {
    const trail = [
        { name: 'Home',      url: SITE_URL + '/' },
        { name: 'Inventory', url: SITE_URL + BROWSE_PATH }
    ];
    if (item.Manufacturer) {
        trail.push({
            name: item.Manufacturer,
            url:  SITE_URL + (liveBrandPath.get(item.Manufacturer) ||
                              BROWSE_PATH + '#' + makeGroupSlug(item.Manufacturer))
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
        if (item.MSRP > 0) {
            priceHtml    = '<span class="price-main">MSRP ' + escapeHtml(formatMoney(item.MSRP)) + '</span>';
            priceSubHtml = '<div class="price-call-note">Call or Text for this Month\'s Discounted Price.</div>';
        } else {
            priceHtml = '<span class="price-call">Call for Price</span>';
        }
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

// Alt text for an item's photos. "16404CHRFIL photo 3" describes nothing to
// a reader or a search engine; the description is what people actually type.
function photoAltFor(item) {
    return item.Description
        || [item.Manufacturer, item.Model].filter(Boolean).join(' ')
        || 'Peach Outdoor equipment';
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
            '<div class="gallery-col">' + renderGallery(photos, photoAltFor(item)) + '</div>' +
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
        '<a href="' + BROWSE_PATH + '">Inventory</a>'
    ];
    if (item.Manufacturer) {
        parts.push('<a href="' + escapeHtml(liveBrandPath.get(item.Manufacturer) ||
                       BROWSE_PATH + '#' + makeGroupSlug(item.Manufacturer)) + '">' +
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
                (liveBrandPath.has(item.Manufacturer)
                    ? '<a class="related-all" href="' + liveBrandPath.get(item.Manufacturer) + '">All ' +
                      escapeHtml(item.Manufacturer) + ' in stock at Peach Outdoor &#8594;</a> '
                    : '') +
                '<a class="related-all" href="' + BROWSE_PATH + '">Browse all Peach Outdoor inventory &#8594;</a>' +
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

// ─── Category + browse list pages ───────────────────────────────────────
// The browse index gives every item URL an internal link. The category pages
// give Google a page whose whole content matches a real query — "tractors for
// sale", "zero-turn mowers" — instead of a home page that mentions it once.
//
// The zero-turn page matters more than its item count suggests: only 2 items
// have "zero turn" anywhere in their description text, so without this page
// the phrase barely exists on the site despite ~30 of them being in stock.

// Departments with fewer items than this get no page of their own — a
// near-empty landing page is worse than none.
const MIN_CATEGORY_ITEMS = 10;

const CATEGORIES = [
    {
        dept: 'TRACTOR', slug: 'tractors-for-sale-clanton-al', nav: 'Tractors',
        title: 'New Tractors for Sale in Clanton, AL | LS, Mahindra, Bad Boy',
        h1:    'New Tractors for Sale in Clanton, Alabama',
        desc:  'Shop new compact and utility tractors at Peach Outdoor in Clanton, Alabama. Authorized LS, Mahindra and Bad Boy dealer. Financing and service on-site. Call 205-280-8838.',
        blurb: 'Peach Outdoor sells new compact and utility tractors from LS, Mahindra and Bad Boy, with used tractors added as they come in. Whether you need a sub-compact for the yard or a 60+ hp utility tractor with a loader, we can match one to your acreage and your implements. We are an authorized dealer, we service what we sell from our own shop on Christian Street, and you can apply for financing online before you come out. We serve Clanton, Chilton County and the surrounding area.'
    },
    {
        dept: 'MOWER', slug: 'zero-turn-mowers-for-sale-clanton-al', nav: 'Zero-Turn Mowers',
        title: 'Zero-Turn Mowers for Sale in Clanton, AL | Bad Boy, Spartan',
        h1:    'Zero-Turn Mowers for Sale in Clanton, Alabama',
        desc:  'Zero-turn lawn mowers for sale at Peach Outdoor in Clanton, Alabama. Bad Boy and Spartan dealer with parts, service and online financing.',
        blurb: 'Zero-turn riding lawn mowers from Bad Boy and Spartan, from homeowner decks up to commercial machines. Parts and service are handled in our own shop, so the mower you buy here is the mower we look after.'
    },
    {
        dept: 'IMP', slug: 'tractor-attachments-implements-clanton-al', nav: 'Attachments',
        title: 'Tractor Attachments & Implements | Clanton, AL',
        h1:    'Tractor Attachments and Implements in Central Alabama',
        desc:  'Box blades, cutters, grapples, augers, hay forks and more. Tractor attachments and implements in stock at Peach Outdoor in Clanton, Alabama.',
        blurb: 'Rotary cutters, box blades, grapples, post hole diggers, auger bits, hay forks and pallet forks, from IronCraft, Bad Boy, Taylor Pittsburgh and Bush Hog. Matching an implement to a tractor you already own? Call us with the horsepower and hitch category and we will tell you what fits.'
    },
    {
        dept: 'CANOPY', slug: 'tractor-canopies-clanton-al', nav: 'Canopies',
        title: 'Tractor Canopies & Sunshades | Clanton, AL',
        h1:    'Tractor Canopies for Sale in Clanton, Alabama',
        desc:  'Tractor canopies and sunshades in stock at Peach Outdoor in Clanton, Alabama, including Burdeshaw Tractor Canopies. Call 205-280-8838.',
        blurb: 'Canopies and sunshades to get you out of the Alabama sun, including Burdeshaw Tractor Canopies built here in the state. Tell us your make and model and we will confirm the fit.'
    },
    {
        dept: 'HANDHELD', slug: 'chainsaws-trimmers-handheld-equipment-clanton-al', nav: 'Handheld',
        title: 'Chainsaws, Trimmers & Handheld Equipment | Clanton, AL',
        h1:    'Handheld Outdoor Power Equipment in Clanton, Alabama',
        desc:  'Chainsaws, hedge trimmers, blowers and handheld outdoor power equipment at Peach Outdoor in Clanton, Alabama. Echo and Bad Boy dealer.',
        blurb: 'Chainsaws, hedge trimmers, blowers and string trimmers from Echo and Bad Boy. Smaller tickets than a tractor, with the same service counter behind them.'
    },
    {
        dept: 'TRAILER', slug: 'utility-equipment-trailers-clanton-al', nav: 'Trailers',
        title: 'Utility & Equipment Trailers for Sale | Clanton, AL',
        h1:    'Utility and Equipment Trailers for Sale in Clanton, Alabama',
        desc:  'Utility and equipment trailers in stock at Peach Outdoor in Clanton, Alabama. Call 205-280-8838 for availability and delivery.',
        blurb: 'Utility and equipment trailers from G2, Caliber and Load Trail, sized from light utility up to equipment haulers. Hauling a tractor you bought here? We will make sure the trailer is rated for it.'
    },
    {
        dept: 'ACCESSORY', slug: 'tractor-mower-accessories-clanton-al', nav: 'Accessories',
        title: 'Tractor & Mower Accessories | Clanton, AL',
        h1:    'Tractor and Mower Accessories in Clanton, Alabama',
        desc:  'Tractor and mower accessories in stock at Peach Outdoor in Clanton, Alabama. Call 205-280-8838.',
        blurb: 'Accessories and add-ons for the equipment we sell. If you do not see what you are after, call us — a lot of this is available to order.'
    }
];


// ─── Brand landing pages ────────────────────────────────────────────────
// The homepage brand tiles used to point at inventory.html?mfg=..., which
// canonicalises to /inventory.html — so to Google there was no page about
// "Mahindra tractors in Clanton" at all, only one search page with filters.
// Each brand below gets a static page whose title, H1 and body are about
// that brand, with every in-stock unit linked straight from the HTML.
//
// mfg must match inventory.json's Manufacturer string exactly.
// Brands under MIN_BRAND_ITEMS are skipped for the same thin-page reason as
// categories.

const MIN_BRAND_ITEMS = 8;

const BRANDS = [
    {
        mfg: 'Mahindra USA', name: 'Mahindra', slug: 'mahindra-tractors-clanton-al',
        guide: '/mahindra-tractors-guide.html',
        title: 'Mahindra Tractor Dealer in Clanton, AL | Peach Outdoor',
        h1:    'Mahindra Tractors for Sale in Clanton, Alabama',
        desc:  'Authorized Mahindra tractor dealer in Clanton, Alabama. New and used Mahindra compact and utility tractors in stock, with on-site service and online financing.',
        blurb: 'Peach Outdoor is an authorized Mahindra dealer in Clanton, Alabama. We are a top-five Mahindra dealer in the nation. We sell new and used Mahindra compact and utility tractors off our lot on Big M Blvd, and we service them in our own shop on Christian Street after the sale. You can apply for financing online before you come out.'
    },
    {
        // Model-line page: only the ROXOR series of Mahindra USA. Has no effect on
        // Mahindra item links (those keep pointing at the Mahindra brand page).
        mfg: 'Mahindra USA', series: 'ROXOR', minItems: 1, name: 'Mahindra Roxor', slug: 'mahindra-roxor-clanton-al',
        title: 'Mahindra Roxor for Sale in Clanton, AL | Peach Outdoor',
        h1:    'Mahindra Roxor for Sale in Clanton, Alabama',
        desc:  'New Mahindra Roxor off-road UTVs for sale at Peach Outdoor in Clanton, Alabama. 2.7L turbo diesel, boxed steel frame, 3,500 lb towing. Call 205-280-8838.',
        blurb: 'The Mahindra Roxor is a heavy-duty, body-on-frame off-road utility vehicle with a 2.7L turbo diesel, a boxed steel frame and 3,500 lb towing capacity. Peach Outdoor is an authorized Mahindra dealer in Clanton, Alabama, and we service what we sell in our own shop. Call for current Roxor availability and pricing.'
    },
    {
        mfg: 'LS Tractor', name: 'LS Tractor', short: 'LS', slug: 'ls-tractors-clanton-al',
        title: 'LS Tractor Dealer in Clanton, AL | Peach Outdoor',
        h1:    'LS Tractors for Sale in Clanton, Alabama',
        desc:  'Authorized LS Tractor dealer in Clanton, Alabama. LS compact and utility tractors, loaders and implements in stock, with on-site service and online financing.',
        blurb: 'Peach Outdoor is an authorized LS Tractor dealer in Clanton, Alabama, and LS is one of the deepest lines on our lot. We are a top-three LS dealer in the nation and the 2026 East Division Top Dealer. We stock LS compact and utility tractors along with matching LS implements, and we service what we sell in our own shop. Financing applications can be done online.'
    },
    {
        mfg: 'Bad Boy', name: 'Bad Boy', slug: 'bad-boy-mowers-tractors-clanton-al',
        title: 'Bad Boy Mowers & Tractors Dealer in Clanton, AL | Peach Outdoor',
        h1:    'Bad Boy Mowers, Tractors and Implements in Clanton, Alabama',
        desc:  'Authorized Bad Boy dealer in Clanton, Alabama. Bad Boy zero-turn mowers, compact tractors, implements and handheld equipment in stock, with parts and service.',
        blurb: 'Peach Outdoor is an authorized Bad Boy dealer in Clanton, Alabama, a top-five Bad Boy dealer in the nation, carrying the whole line: Bad Boy compact tractors, zero-turn mowers, tractor implements and handheld equipment. Parts and service are handled in our own shop, so the Bad Boy you buy here is the one we look after.'
    },
    {
        mfg: 'IronCraft', name: 'IronCraft', slug: 'ironcraft-implements-clanton-al',
        title: 'IronCraft Implements & Attachments | Clanton, AL | Peach Outdoor',
        h1:    'IronCraft Tractor Implements in Clanton, Alabama',
        desc:  'IronCraft grapples, box blades, rotary cutters, disc harrows, tillers and post hole diggers in stock at Peach Outdoor in Clanton, Alabama.',
        blurb: 'IronCraft grapples, box blades, rotary cutters, disc harrows, tillers, post hole diggers and more, in stock in Clanton. Not sure what fits your tractor? Call us with the horsepower and hitch category and we will match it, whether the tractor came from us or not.'
    },
    {
        mfg: 'Spartan Mowers', name: 'Spartan', slug: 'spartan-mowers-clanton-al',
        title: 'Spartan Mowers Dealer in Clanton, AL | Peach Outdoor',
        h1:    'Spartan Zero-Turn Mowers in Clanton, Alabama',
        desc:  'Authorized Spartan Mowers dealer in Clanton, Alabama. Spartan zero-turn mowers in stock, with parts, service and online financing.',
        blurb: 'Peach Outdoor is an authorized Spartan Mowers dealer in Clanton, Alabama. We stock Spartan zero-turn mowers and handle parts and service in our own shop.'
    },
    {
        mfg: 'Bush Hog', name: 'Bush Hog', slug: 'bush-hog-cutters-clanton-al',
        title: 'Bush Hog Cutters & Implements | Clanton, AL | Peach Outdoor',
        h1:    'Bush Hog Rotary Cutters and Implements in Clanton, Alabama',
        desc:  'Bush Hog rotary cutters and implements in stock at Peach Outdoor in Clanton, Alabama. Call 205-280-8838.',
        blurb: 'Bush Hog rotary cutters and implements, in stock in Clanton. Tell us what tractor you are running and we will make sure the cutter is the right size for it.'
    }
];

// ─── Out-of-state delivery pages ─────────────────────────────────────────
//
// Roughly 30% of tractor sales ship out of state (Sales by State report,
// Oct 2026: AL 261, GA 26, TN 21, MS 20, LA 11, KY 7). Each page below targets
// "new tractors <state>" searches. The boilerplate is generated; the optional
// fields are what make a page genuinely different from its siblings, so fill
// them in when there is something real to say:
//   towns:   ['Rome', 'Dalton']  -> "recently delivered to ..." sentence
//   note:    'Free-form paragraph about this state' (turnaround, popular models)
//   reviews: [{ quote: '...', who: 'J. Smith, Cartersville' }]  (with permission)
// Add Florida / South Carolina here the same way when their volume justifies it.

const STATES = [
    { name: 'Georgia',     slug: 'tractors-delivered-to-georgia',     towns: [], note: '', reviews: [] },
    { name: 'Tennessee',   slug: 'tractors-delivered-to-tennessee',   towns: [], note: '', reviews: [] },
    { name: 'Mississippi', slug: 'tractors-delivered-to-mississippi', towns: [], note: '', reviews: [] },
    { name: 'Louisiana',   slug: 'tractors-delivered-to-louisiana',   towns: [], note: '', reviews: [] },
    { name: 'Kentucky',    slug: 'tractors-delivered-to-kentucky',    towns: [], note: '', reviews: [] }
];

function statePath(st) { return '/inventory/' + st.slug; }

function buildStatePage(st, tractors, live, liveBrands) {
    const path = statePath(st);
    const newCount = tractors.filter(e => !e.item.Used).length;

    // A handful of units per brand: enough to be useful, short of cloning the
    // main tractor page.
    const byMfg = new Map();
    for (const e of tractors) {
        const m = e.item.Manufacturer || 'Other';
        if (!byMfg.has(m)) byMfg.set(m, []);
        byMfg.get(m).push(e);
    }
    const noPrice = e => (e.seo.priceText && !/call/i.test(e.seo.priceText)) ? 0 : 1;
    const sections = [...byMfg.keys()].sort().map(m => {
        const all  = byMfg.get(m).sort((a, b) => noPrice(a) - noPrice(b) || a.seo.headline.localeCompare(b.seo.headline));
        const rows = all.slice(0, 6).map(e =>
            '<li><a href="/inventory/' + escapeHtml(e.seo.slug) + '">' +
                '<span class="bi-name">' + escapeHtml(e.seo.headline) + '</span>' +
                '<span class="bi-meta">' + (e.item.Used ? 'Used' : 'New') + '</span>' +
                '<span class="bi-price">' + escapeHtml(e.seo.priceText) + '</span></a></li>').join('');
        const more = liveBrandPath.has(m)
            ? '<p><a href="' + liveBrandPath.get(m) + '">See all ' + escapeHtml(m) + ' in stock (' + byMfg.get(m).length + ')</a></p>' : '';
        return '<section class="brand-block"><h2>' + escapeHtml(m) + ' tractors <span class="count">' +
               byMfg.get(m).length + ' in stock</span></h2><ul class="browse-list">' + rows + '</ul>' + more + '</section>';
    }).join('\n');

    let lede = 'Peach Outdoor ships new LS, Mahindra and Bad Boy tractors from Clanton, Alabama to buyers in ' +
               escapeHtml(st.name) + '. Delivery is by freight carrier, and <a href="/delivery.html">freight is free on select units</a>; ' +
               'call for a quote to your address. <strong>' + tractors.length + ' tractors in stock' +
               (newCount < tractors.length ? ' (' + newCount + ' new)' : '') + '.</strong> ' +
               'Sales <a href="tel:2052808838">(205) 280-8838</a>.';
    if (st.towns.length) lede += ' We have recently delivered to customers in ' + escapeHtml(st.towns.join(', ')) + '.';
    if (st.note) lede += ' ' + escapeHtml(st.note);
    if (st.reviews.length) lede += '<br><br>' + st.reviews.map(r =>
        '&ldquo;' + escapeHtml(r.quote) + '&rdquo; &mdash; ' + escapeHtml(r.who)).join('<br>');

    const stateNav = STATES.map(o =>
        '<a class="' + (o.slug === st.slug ? 'here' : '') + '" href="' + statePath(o) + '">' + escapeHtml(o.name) + '</a>').join('');

    return renderListShell({
        title: 'New Tractors Delivered to ' + st.name + ' | LS, Mahindra, Bad Boy | Peach Outdoor',
        desc:  'Buy a new LS, Mahindra or Bad Boy tractor from Peach Outdoor in Clanton, Alabama and have it delivered to ' + st.name + '. Freight is free on select units. Call 205-280-8838.',
        h1:    'New Tractors Delivered to ' + st.name,
        entries: tractors,
        canonicalPath: path,
        crumbs: [
            { name: 'Home', path: '/' },
            { name: 'Delivery', path: '/delivery.html' },
            { name: st.name, path: path }
        ],
        crumbHtml: '<a href="/">Home</a><span class="crumb-sep">&#8250;</span>' +
                   '<a href="/delivery.html">Delivery</a><span class="crumb-sep">&#8250;</span>' +
                   '<span aria-current="page">' + escapeHtml(st.name) + '</span>',
        lede, catNav: stateNav, brandNav: renderBrandNav(liveBrands, null), jumps: '', sections
    });
}

// Section headings on brand pages, in display order.
const DEPT_LABELS = {
    TRACTOR: 'Tractors', MOWER: 'Zero-Turn Mowers', UTV: 'UTVs', LOADER: 'Loaders',
    IMP: 'Implements & Attachments', HANDHELD: 'Handheld Equipment', CANOPY: 'Canopies',
    TRAILER: 'Trailers', ACCESSORY: 'Accessories', PARTS: 'Parts', OTHER: 'Other Equipment'
};
const DEPT_ORDER = Object.keys(DEPT_LABELS);

function brandPath(brand) { return '/inventory/' + brand.slug; }

// Manufacturer string -> brand page path, for brands that actually got a page.
// Filled in by main() before any page is rendered.
const liveBrandPath = new Map();

function categoryPath(cat) { return '/inventory/' + cat.slug; }

// Shared CSS and document shell for the browse index and every category page.
function renderListShell(opts) {
    const schema = {
        "@context": "https://schema.org",
        "@type": "CollectionPage",
        "name": opts.h1,
        "description": opts.desc,
        "url": SITE_URL + opts.canonicalPath,
        "isPartOf": { "@type": "WebSite", "name": "Peach Outdoor", "url": SITE_URL + '/' }
    };
    if (opts.about) schema.about = { "@type": "Brand", "name": opts.about };
    // Tie the page to the dealership defined on the homepage and list the units
    // so Google reads the page as a hub for the item pages.
    schema.publisher = { "@id": SITE_URL + '/#dealer' };
    if (opts.entries && opts.entries.length) {
        schema.mainEntity = {
            "@type": "ItemList",
            "numberOfItems": opts.entries.length,
            "itemListElement": opts.entries.slice(0, 100).map((e, i) => ({
                "@type": "ListItem", "position": i + 1,
                "url": SITE_URL + '/inventory/' + e.seo.slug
            }))
        };
    }

    const crumbs = {
        "@context": "https://schema.org",
        "@type": "BreadcrumbList",
        "itemListElement": opts.crumbs.map((c, i) => ({
            "@type": "ListItem", "position": i + 1, "name": c.name, "item": SITE_URL + c.path
        }))
    };

    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${escapeHtml(opts.title)}</title>
    <meta name="description" content="${escapeHtml(opts.desc)}">
    <link rel="canonical" href="${SITE_URL}${opts.canonicalPath}">
    <meta property="og:type" content="website">
    <meta property="og:title" content="${escapeHtml(opts.title)}">
    <meta property="og:description" content="${escapeHtml(opts.desc)}">
    <meta property="og:url" content="${SITE_URL}${opts.canonicalPath}">
    <meta property="og:image" content="${FALLBACK_OG_IMAGE}">
    <script type="application/ld+json">${safeJSONForScript(schema)}</script>
    <script type="application/ld+json">${safeJSONForScript(crumbs)}</script>
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
        .wrap { max-width: 1200px; margin: 0 auto; padding: 22px 20px 60px; }
        .crumbs { font-size: 0.8em; color: var(--text-muted); margin-bottom: 16px; }
        .crumbs a { color: var(--text-secondary); text-decoration: none; }
        .crumbs a:hover { color: var(--accent); text-decoration: underline; }
        .crumb-sep { margin: 0 7px; }
        h1 { font-size: 1.7em; margin-bottom: 8px; line-height: 1.25; }
        .lede {
            color: var(--text-secondary); margin-bottom: 20px;
            font-size: 0.95em; line-height: 1.65; max-width: 880px;
        }
        .lede a { color: var(--accent); text-decoration: none; }
        .lede strong { color: var(--text-primary); }
        .cat-nav { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 26px; }
        .cat-nav a {
            background: var(--charcoal-mid); border: 1px solid var(--charcoal-border);
            border-radius: 999px; padding: 7px 15px; font-size: 0.85em;
            color: var(--text-primary); text-decoration: none;
        }
        .cat-nav a:hover { border-color: var(--accent); color: var(--accent); }
        .cat-nav a.here { border-color: var(--accent); color: var(--accent); font-weight: 600; }
        .cat-nav a span { color: var(--text-muted); }
        .brand-nav { align-items: center; margin-top: -14px; }
        .nav-label { color: var(--text-muted); font-size: 0.8em; margin-right: 2px; }
        .brand-block h2 a { color: var(--text-primary); text-decoration: none; }
        .brand-block h2 a:hover { color: var(--accent); text-decoration: underline; }
        .lineup { color: var(--text-secondary); font-size: 0.9em; line-height: 1.6;
                  margin: -8px 0 20px; max-width: 880px; }
        .lineup strong { color: var(--text-primary); }
        .jumps { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 30px; }
        .jump {
            background: var(--charcoal-mid); border: 1px solid var(--charcoal-border);
            border-radius: 999px; padding: 6px 14px; font-size: 0.85em;
            color: var(--text-primary); text-decoration: none;
        }
        .jump span { color: var(--text-muted); }
        .jump:hover { border-color: var(--accent); color: var(--accent); }
        .brand-block { margin-bottom: 34px; scroll-margin-top: 80px; }
        .brand-block h2 {
            font-size: 1.1em; padding-bottom: 8px; margin-bottom: 10px;
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
        .tail {
            margin-top: 34px; padding-top: 20px;
            border-top: 1px solid var(--charcoal-border);
            color: var(--text-secondary); font-size: 0.9em; line-height: 1.7;
        }
        .tail a { color: var(--accent); text-decoration: none; }
        @media (max-width: 600px) {
            .top-bar { padding: 12px 16px; }
            .wrap { padding: 18px 16px 48px; }
            h1 { font-size: 1.3em; }
        }
    </style>
</head>
<body>
    <div class="top-bar">
        <a href="/">&#8592; Peach Outdoor Home</a>
        <a href="/inventory.html">Search &amp; filter inventory</a>
    </div>
    <div class="wrap">
        <nav class="crumbs" aria-label="Breadcrumb">${opts.crumbHtml}</nav>
        <h1>${escapeHtml(opts.h1)}</h1>
        <p class="lede">${opts.lede}</p>
        ${opts.lineup || ''}
        <nav class="cat-nav">${opts.catNav}</nav>
        ${opts.brandNav ? '<nav class="cat-nav brand-nav"><span class="nav-label">Shop by brand:</span>' + opts.brandNav + '</nav>' : ''}
        ${opts.jumps || ''}
${opts.sections}
        <div class="tail">
            Not seeing it? Call sales on <a href="tel:2052808838">(205) 280-8838</a>,
            or <a href="/inventory.html">search the full inventory</a>.
            Peach Outdoor, 1940 Big M Blvd, Clanton, AL 35046.
        </div>
    </div>
</body>
</html>
`;
}

// Group entries by manufacturer and render the linked sections.
function renderBrandSections(entries, showDept, groupByDept) {
    const byMfg = new Map();
    for (const e of entries) {
        const key = groupByDept
            ? (DEPT_LABELS[(e.item.Department || '').trim().toUpperCase()] || 'Other Equipment')
            : (e.item.Manufacturer || 'Other Equipment');
        if (!byMfg.has(key)) byMfg.set(key, []);
        byMfg.get(key).push(e);
    }
    const order = n => { const i = Object.values(DEPT_LABELS).indexOf(n); return i < 0 ? 99 : i; };
    const names = [...byMfg.keys()].sort(groupByDept
        ? (a, b) => order(a) - order(b)
        : (a, b) => a.localeCompare(b));

    const jumps = names.length > 1
        ? '<div class="jumps">' + names.map(m =>
            '<a class="jump" href="#' + escapeHtml(makeGroupSlug(m)) + '">' + escapeHtml(m) +
            ' <span>(' + byMfg.get(m).length + ')</span></a>').join('') + '</div>'
        : '';

    const sections = names.map(m => {
        const group = byMfg.get(m).sort((a, b) => a.seo.headline.localeCompare(b.seo.headline));
        const rows = group.map(e =>
            '<li><a href="/inventory/' + escapeHtml(e.seo.slug) + '">' +
                '<span class="bi-name">' + escapeHtml(e.seo.headline) + '</span>' +
                '<span class="bi-meta">' + (e.item.Used ? 'Used' : 'New') +
                    (showDept && e.item.Department ? ' &middot; ' + escapeHtml(e.item.Department) : '') +
                '</span>' +
                '<span class="bi-price">' + escapeHtml(e.seo.priceText) + '</span>' +
            '</a></li>').join('');

        return '<section class="brand-block" id="' + escapeHtml(makeGroupSlug(m)) + '">' +
                    '<h2>' + (!groupByDept && liveBrandPath.has(m)
                        ? '<a href="' + liveBrandPath.get(m) + '">' + escapeHtml(m) + '</a>'
                        : escapeHtml(m)) +
                        ' <span class="count">' + group.length + ' in stock</span></h2>' +
                    '<ul class="browse-list">' + rows + '</ul>' +
               '</section>';
    }).join('\n');

    return { jumps, sections, names };
}

// Category pills shared by every list page, so each links to all the others.
function renderCatNav(live, currentSlug) {
    const all = '<a class="' + (currentSlug ? '' : 'here') + '" href="' + BROWSE_PATH + '">Everything</a>';
    const pills = live.map(c =>
        '<a class="' + (c.cat.slug === currentSlug ? 'here' : '') + '" href="' + categoryPath(c.cat) + '">' +
        escapeHtml(c.cat.nav) + ' <span>(' + c.entries.length + ')</span></a>').join('');
    return all + pills;
}

function buildBrowsePage(entries, live, liveBrands) {
    const { jumps, sections, names } = renderBrandSections(entries, true);

    const title = 'All Inventory in Stock — Clanton, AL | Peach Outdoor';
    const desc  = 'Browse all ' + entries.length + ' items in stock at Peach Outdoor in Clanton, Alabama — ' +
                  names.slice(0, 6).join(', ') + ' and more. Call 205-280-8838.';

    const lede = entries.length + ' items in stock in Clanton, Alabama. Sales 205-280-8838 &middot; ' +
                 '1940 Big M Blvd, Clanton, AL 35046. Prefer to filter by type, price or condition? ' +
                 'Use the <a href="/inventory.html">inventory search</a>.';

    return renderListShell({
        title, desc, h1: 'All Inventory at Peach Outdoor',
        canonicalPath: BROWSE_PATH,
        crumbs: [{ name: 'Home', path: '/' }, { name: 'Inventory', path: BROWSE_PATH }],
        crumbHtml: '<a href="/">Home</a><span class="crumb-sep">&#8250;</span>' +
                   '<span aria-current="page">Inventory</span>',
        lede, catNav: renderCatNav(live, null), brandNav: renderBrandNav(liveBrands, null), jumps, sections
    });
}

function buildCategoryPage(cat, entries, live, liveBrands) {
    const { jumps, sections } = renderBrandSections(entries, false);
    const path = categoryPath(cat);

    const lede = escapeHtml(cat.blurb) + ' <strong>' + entries.length + ' in stock.</strong> ' +
                 'Sales <a href="tel:2052808838">(205) 280-8838</a> &middot; ' +
                 '<a href="' + BROWSE_PATH + '">see everything in stock</a>. ' +
                 'We deliver across the Southeast &mdash; <a href="/delivery.html">freight is free on select units</a>.';

    return renderListShell({
        title: cat.title, desc: cat.desc, h1: cat.h1, entries,
        canonicalPath: path,
        crumbs: [
            { name: 'Home', path: '/' },
            { name: 'Inventory', path: BROWSE_PATH },
            { name: cat.nav, path: path }
        ],
        crumbHtml: '<a href="/">Home</a><span class="crumb-sep">&#8250;</span>' +
                   '<a href="' + BROWSE_PATH + '">Inventory</a><span class="crumb-sep">&#8250;</span>' +
                   '<span aria-current="page">' + escapeHtml(cat.nav) + '</span>',
        lede, catNav: renderCatNav(live, cat.slug), brandNav: renderBrandNav(liveBrands, null), jumps, sections
    });
}

function renderBrandNav(liveBrands, currentSlug) {
    return liveBrands.map(b =>
        '<a class="' + (b.brand.slug === currentSlug ? 'here' : '') + '" href="' + brandPath(b.brand) + '">' +
        escapeHtml(b.brand.name) + ' <span>(' + b.entries.length + ')</span></a>').join('');
}

// "Tractors: 1600, 4500 Series · Zero-turns: Rambler, Maverick" — built from
// the Series field, so it always matches what is actually on the lot.
function renderLineup(brand, entries) {
    const parts = [];
    for (const [dept, label] of [['TRACTOR', 'Tractor series in stock'], ['MOWER', 'Mower models in stock']]) {
        const counts = new Map();
        for (const e of entries) {
            if ((e.item.Department || '').trim().toUpperCase() !== dept) continue;
            const ser = String(e.item.Series || '').trim();
            if (!ser || ser === '-') continue;
            counts.set(ser, (counts.get(ser) || 0) + 1);
        }
        if (!counts.size) continue;
        const list = [...counts.keys()]
            .sort((a, b) => a.localeCompare(b, 'en', { numeric: true }))
            .map(ser => escapeHtml(dept === 'TRACTOR'
                ? (brand.short || brand.name) + ' ' + ser + ' Series'
                // "RAMBLER" -> "Rambler"; codes like "SRT-XDE" stay as they are.
                : (/^[A-Z]{4,}$/.test(ser) ? ser.charAt(0) + ser.slice(1).toLowerCase() : ser)))
            .join(', ');
        parts.push('<strong>' + label + ':</strong> ' + list);
    }
    return parts.length ? '<p class="lineup">' + parts.join(' &middot; ') + '</p>' : '';
}

function buildBrandPage(brand, entries, live, liveBrands) {
    const { jumps, sections } = renderBrandSections(entries, false, true);
    const path   = brandPath(brand);
    const search = '/inventory.html?mfg=' + encodeURIComponent(brand.mfg) +
                   (brand.series ? '&series=' + encodeURIComponent(brand.series) : '');
    const newCount  = entries.filter(e => !e.item.Used).length;
    const usedCount = entries.length - newCount;

    const tPrices = entries.filter(e => /tractor/i.test(e.item.Department || ''))
        .map(e => Number(e.item.Web_Price != null ? e.item.Web_Price : e.item.MSRP)).filter(n => n > 0);
    const priceNote = tPrices.length >= 3
        ? ' In-stock tractors are listed from ' + escapeHtml(formatMoney(Math.round(Math.min(...tPrices))).replace('.00', '')) +
          ' to ' + escapeHtml(formatMoney(Math.round(Math.max(...tPrices))).replace('.00', '')) + ' (MSRP or sale price).'
        : '';
    const lede = escapeHtml(brand.blurb) + priceNote + ' <strong>' + entries.length + ' ' + escapeHtml(brand.name) +
                 ' units in stock' + (usedCount ? ' (' + newCount + ' new, ' + usedCount + ' used)' : '') +
                 '.</strong> Sales <a href="tel:2052808838">(205) 280-8838</a> &middot; ' +
                 '<a href="' + escapeHtml(search) + '">filter ' + escapeHtml(brand.name) + ' by price or type</a>. ' +
                 'We deliver across the Southeast &mdash; <a href="/delivery.html">freight is free on select units</a>.' +
                 (brand.guide ? ' New to Mahindra? Read our <a href="' + escapeHtml(brand.guide) + '">Mahindra tractor buyer&rsquo;s guide</a>.' : '');

    return renderListShell({
        title: brand.title, desc: brand.desc, h1: brand.h1, about: brand.name, entries,
        canonicalPath: path,
        crumbs: [
            { name: 'Home', path: '/' },
            { name: 'Inventory', path: BROWSE_PATH },
            { name: brand.name, path: path }
        ],
        crumbHtml: '<a href="/">Home</a><span class="crumb-sep">&#8250;</span>' +
                   '<a href="' + BROWSE_PATH + '">Inventory</a><span class="crumb-sep">&#8250;</span>' +
                   '<span aria-current="page">' + escapeHtml(brand.name) + '</span>',
        lede, lineup: renderLineup(brand, entries),
        catNav: renderCatNav(live, null).replace('class="here"', 'class=""'),
        brandNav: renderBrandNav(liveBrands, brand.slug),
        jumps, sections
    });
}

// ─── Sitemap + robots ────────────────────────────────────────────────────

function buildSitemap(entries, live, liveBrands) {
    const today = new Date().toISOString().slice(0, 10);
    const staticPages = [
        { loc: SITE_URL + '/',                   priority: '1.0', changefreq: 'weekly' },
        { loc: SITE_URL + '/inventory.html',     priority: '0.9', changefreq: 'daily' },
        { loc: SITE_URL + BROWSE_PATH,           priority: '0.9', changefreq: 'daily' },
        { loc: SITE_URL + '/financing.html',     priority: '0.5', changefreq: 'monthly' },
        { loc: SITE_URL + '/about.html',         priority: '0.5', changefreq: 'monthly' },
        { loc: SITE_URL + '/delivery.html',      priority: '0.6', changefreq: 'monthly' },
        { loc: SITE_URL + '/configurator.html',  priority: '0.5', changefreq: 'monthly' },
        { loc: SITE_URL + '/mahindra-tractors-guide.html', priority: '0.6', changefreq: 'monthly' }
    ];

    // Category landing pages rank for the query, so they sit above item pages
    // in priority and below the two hub pages.
    for (const c of live) {
        staticPages.push({ loc: SITE_URL + categoryPath(c.cat), priority: '0.8', changefreq: 'daily' });
    }
    for (const st of STATES) {
        staticPages.push({ loc: SITE_URL + statePath(st), priority: '0.6', changefreq: 'weekly' });
    }
    for (const b of liveBrands) {
        staticPages.push({ loc: SITE_URL + brandPath(b.brand), priority: '0.8', changefreq: 'daily' });
    }

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

    // ── Brand pages that will exist. Resolved before pass 2 so item-page
    // breadcrumbs and related blocks can link to them.
    const liveBrands = [];
    for (const brand of BRANDS) {
        const bEntries = entries.filter(e => (e.item.Manufacturer || '') === brand.mfg &&
            (!brand.series || String(e.item.Series || '').trim().toUpperCase() === brand.series));
        if (bEntries.length >= (brand.minItems || MIN_BRAND_ITEMS)) {
            liveBrands.push({ brand, entries: bEntries });
            if (!brand.series) liveBrandPath.set(brand.mfg, brandPath(brand));
        } else {
            console.log('[build] Skipping brand page ' + brand.name + ' — only ' + bEntries.length + ' item(s).');
        }
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

    // ── Category landing pages. Only departments with real depth get one;
    // a page with three items on it is a thin page, which is worse than none.
    const live = [];
    for (const cat of CATEGORIES) {
        const catEntries = entries.filter(e => (e.item.Department || '').trim().toUpperCase() === cat.dept);
        if (catEntries.length >= MIN_CATEGORY_ITEMS) {
            live.push({ cat, entries: catEntries });
        } else {
            console.log('[build] Skipping category ' + cat.nav + ' — only ' +
                        catEntries.length + ' item(s), under the ' + MIN_CATEGORY_ITEMS + ' minimum.');
        }
    }

    // A category slug colliding with an item slug would silently overwrite a
    // page. Item slugs end in -<InventoryID>, so this should never fire.
    for (const c of live) {
        if (slugsSeen.has(c.cat.slug)) {
            throw new Error('Category slug ' + c.cat.slug + ' collides with an item page');
        }
    }
    for (const b of liveBrands) {
        if (slugsSeen.has(b.brand.slug) || CATEGORIES.some(c => c.slug === b.brand.slug)) {
            throw new Error('Brand slug ' + b.brand.slug + ' collides with another page');
        }
    }

    for (const c of live) {
        fs.writeFileSync(path.join(OUTPUT_DIR, c.cat.slug + '.html'),
                         buildCategoryPage(c.cat, c.entries, live, liveBrands), 'utf8');
        console.log('[build] Wrote ' + categoryPath(c.cat) + ' (' + c.entries.length + ' items)');
    }

    for (const b of liveBrands) {
        fs.writeFileSync(path.join(OUTPUT_DIR, b.brand.slug + '.html'),
                         buildBrandPage(b.brand, b.entries, live, liveBrands), 'utf8');
        console.log('[build] Wrote ' + brandPath(b.brand) + ' (' + b.entries.length + ' items)');
    }

    const tractorEntries = entries.filter(e => (e.item.Department || '').trim().toUpperCase() === 'TRACTOR');
    for (const st of STATES) {
        fs.writeFileSync(path.join(OUTPUT_DIR, st.slug + '.html'),
                         buildStatePage(st, tractorEntries.slice(), live, liveBrands), 'utf8');
        console.log('[build] Wrote ' + statePath(st) + ' (' + tractorEntries.length + ' tractors)');
    }

    fs.writeFileSync(path.join(OUTPUT_DIR, BROWSE_FILE), buildBrowsePage(entries, live, liveBrands), 'utf8');
    console.log('[build] Wrote inventory/' + BROWSE_FILE + ' (browse index, ' + entries.length + ' links) -> ' + BROWSE_PATH);

    fs.writeFileSync(SITEMAP_PATH, buildSitemap(entries, live, liveBrands), 'utf8');
    console.log('[build] Wrote sitemap.xml');

    fs.writeFileSync(ROBOTS_PATH, buildRobots(), 'utf8');
    console.log('[build] Wrote robots.txt');

    console.log('[build] Done.');
}

main();
