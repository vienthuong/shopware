import { test, expect } from '@playwright/test';

// Repro spec for issue #32: selected variant option name missing in CMS product-slider card.
// Healthy behaviour: the option text 'Repro-Stream' (from property group 'Format') appears
// in the product-variant-characteristics-text area of the slider card.
// Bug: product.variation is not loaded for products fetched via the CMS static slider,
// so the characteristics area is blank (box-standard.html.twig:142 loop yields nothing).

test('variant option name visible in CMS product-slider card', async ({ page }) => {
    // Navigate to the category page that hosts the CMS product-slider.
    // The category name 'Repro Category' yields the SEO path '/Repro-Category/'.
    await page.goto('/Repro-Category/');

    // Precondition: the CMS product-slider region must be present.
    // aria-label is "Product gallery containing %total% items" (storefront.en.json:886).
    const slider = page.getByRole('region', { name: /Product gallery containing/i });
    await slider.waitFor({ state: 'visible', timeout: 20000 })
        .catch(() => { throw new Error('PRECONDITION_NOT_FOUND: CMS product-slider region not rendered on /Repro-Category/'); });

    // Precondition: confirm at least one product card link is present inside the slider.
    const firstCard = slider.getByRole('link').first();
    await firstCard.waitFor({ state: 'visible', timeout: 10000 })
        .catch(() => { throw new Error('PRECONDITION_NOT_FOUND: no product card link found inside the product-slider region'); });

    // Symptom assertion: the variant option text 'Repro-Stream' must be visible in the slider card.
    // Rendered by box-standard.html.twig lines 142-151 via `product.variation`.
    // Buggy version: product.variation empty → text absent → assertion fails → reproduced.
    // Fixed version: product.variation loaded → text visible → assertion passes → not_reproduced.
    await expect(slider.getByText(/Repro-Stream/i)).toBeVisible({ timeout: 10000 });
});
