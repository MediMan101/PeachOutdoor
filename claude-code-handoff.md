# Handoff: PeachOutdoor brand landing pages (SEO)

Repo: MediMan101/PeachOutdoor (Netlify, `node build.js` at deploy)

## Problem
Search Console shows zero queries for "Mahindra tractor", "LS Tractor", "Bad Boy mowers",
"IronCraft implements" (incl. "+ Clanton Alabama" variants). Cause: no page targets those
terms. Homepage brand tiles linked to `inventory.html?mfg=...`, which canonicalises to
`/inventory.html`, so Google sees one filtered search page, not brand pages.

## Fix (in brand-pages.patch — apply first)
1. `git pull --rebase`
2. `git apply brand-pages.patch` (patch is against commit 7b424cc)
3. `node build.js` and confirm it writes six `/inventory/<brand>-clanton-al` pages
4. Commit and push

What the patch does:
- build.js: `BRANDS` config + `buildBrandPage()` generating
  mahindra-tractors-clanton-al, ls-tractors-clanton-al, bad-boy-mowers-tractors-clanton-al,
  ironcraft-implements-clanton-al, spartan-mowers-clanton-al, bush-hog-cutters-clanton-al
  (MIN_BRAND_ITEMS = 8). Brand-specific title/H1/meta/blurb, all units linked in HTML,
  grouped by department, series list built from the Series field, CollectionPage schema
  with `about: Brand`.
- Brand pages added to sitemap; item breadcrumbs + "related" blocks link to them;
  category/browse pages get a "Shop by brand" row.
- index.html: new title "Tractor Dealer in Clanton, AL | Mahindra, LS & Bad Boy | Peach Outdoor";
  Mahindra/LS/Bad Boy tiles and footer Quick Links point to brand pages.
- lineup.html "See In-Stock" buttons and about.html brand pills point to brand pages.

## Still to do
- John to review each brand blurb in BRANDS (build.js). "Authorized dealer" used only for
  Mahindra, LS, Bad Boy, Spartan.
- Some item Descriptions contain internal notes ("** JAY **Spartan KGZ...", "AT SHOP...")
  that leak into item page titles. Clean up in SalesMan / move to Notes.
- After deploy: resubmit sitemap in Search Console; URL Inspection → Request Indexing on
  the Mahindra, LS, Bad Boy and IronCraft pages.
- Possible next steps: Google Business Profile, unique copy on top-selling item pages.
