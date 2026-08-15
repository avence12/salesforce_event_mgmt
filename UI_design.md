# UI_design.md — Salesforce Lightning Design System (SLDS) Design Specification

**Purpose**: This document serves as the guideline for generating the UI of our company's CRM system (Salesforce LWC), ensuring visual and interaction styles strictly align with official Salesforce Lightning Experience / SLDS (Salesforce Lightning Design System) standards. All pages, components, and prototypes should adhere to this standard.

**Version Baseline**: SLDS 2 (Styling Hooks with `--slds-g-*` prefix) is adopted as the primary standard, maintaining backward compatibility with SLDS 1 (Design Tokens with `--lwc-*` prefix, officially marked as legacy). Salesforce updates Release Notes quarterly (Spring/Summer/Winter). Prior to actual project rollout, verify values against the current SLDS version in your company's org.

---

## 1. Design Principles

Salesforce's four official design principles, in order of priority from top to bottom:

1. **Clarity**: Interface language, icons, and states should be immediately understandable without requiring extra explanation.
2. **Efficiency**: Minimize the clicks and cognitive load required for users to complete tasks.
3. **Consistency**: The same components must behave and appear consistently across different pages without reinventing styles.
4. **Beauty**: Consider visual polish only after satisfying the first three principles; never sacrifice usability for aesthetics.

---

## 2. Color System

Always use SLDS Global Styling Hooks (CSS custom properties, `--slds-g-color-*`). Hardcoding hex color codes inside components is strictly prohibited.

### 2.1 Brand Colors

| Usage | Styling Hook | Hex |
|---|---|---|
| Primary Brand Color (CTA, Links, Focus) | `--slds-g-color-brand-base-50` | `#0176D3` |
| Brand Color Hover / Light | `--slds-g-color-brand-base-60` | `#1B96FF` |
| Brand Color Active / Dark | `--slds-g-color-brand-base-40` | `#0B5CAB` |
| Brand Color Darkest (Text, for contrast) | `--slds-g-color-brand-base-30` | `#014486` |

### 2.2 Semantic Colors

| State | Styling Hook | Hex |
|---|---|---|
| Success | `--slds-g-color-success-base-50` | `#2E844A` |
| Success (Light) | `--slds-g-color-success-base-70` | `#45C65A` |
| Warning | `--slds-g-color-warning-base-60` | `#DD7A01` |
| Warning (Dark) | `--slds-g-color-warning-base-50` | `#A96404` |
| Error / Destructive | `--slds-g-color-error-base-50` | `#EA001E` |
| Error (Dark, for text) | `--slds-g-color-error-base-40` | `#BA0517` |

### 2.3 Neutral Grayscale (Neutral / Gray)

| Usage | Styling Hook | Hex |
|---|---|---|
| Pure White (Cards, Modal background) | `--slds-g-color-neutral-base-100` | `#FFFFFF` |
| Page Background | `--slds-g-color-neutral-base-95` | `#F3F3F3` |
| Borders, Dividers | `--slds-g-color-neutral-base-80` | `#C9C9C9` |
| Secondary Text, Placeholder | `--slds-g-color-neutral-base-50` | `#747474` |
| Primary Text, Headings | `--slds-g-color-neutral-base-10` | `#181818` |

**Rules**:

- Primary CTA buttons must only use brand blue; do not invent other primary colors.
- State colors (success/warning/error) are only used for their corresponding semantics, not for decorative purposes.
- Text contrast must comply with WCAG 2.1 AA (regular text ≥ 4.5:1, large text/icons ≥ 3:1).

---

## 3. Typography

```css
font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Salesforce Sans",
  Roboto, Helvetica, Arial, sans-serif;
```

- Body text base size: `0.8125rem` (13px).
- Heading hierarchy must strictly use SLDS built-in utility classes; do not customize font sizes:

| Class | Usage |
|---|---|
| `slds-text-heading_large` | Main page heading |
| `slds-text-heading_medium` | Section heading |
| `slds-text-heading_small` | Card / Block heading |
| `slds-text-title` / `slds-text-title_caps` | Form / Field group subheading |
| `slds-text-body_regular` | Regular body text |
| `slds-text-body_small` | Helper text, Timestamps |

- For Traditional Chinese content, Noto Sans TC is recommended as a fallback to avoid cross-platform inconsistencies caused by non-standard fonts.

---

## 4. Spacing & Sizing

SLDS adopts a fixed scale for spacing. Always use utility classes (`slds-p-around_*`, `slds-m-top_*`) or corresponding hooks; do not hardcode pixel (`px`) values.

| Name | Value | Utility Class Example |
|---|---|---|
| xx-small | 0.125rem (2px) | `slds-p-around_xx-small` |
| x-small | 0.25rem (4px) | `slds-p-around_x-small` |
| small | 0.5rem (8px) | `slds-p-around_small` |
| medium | 0.75rem (12px) | `slds-p-around_medium` |
| large | 1rem (16px) | `slds-p-around_large` |
| x-large | 1.5rem (24px) | `slds-p-around_x-large` |
| xx-large | 3rem (48px) | `slds-p-around_xx-large` |

---

## 5. Layout & Grid

- Grid system is based on Flexbox: `slds-grid` + `slds-col`, supporting 2/3/4/5/6/12 column ratios (e.g., `slds-size_4-of-6`).
- Responsive breakpoints: Small `480px`, Medium `768px`, Large `1024px`.
- All custom blocks that are not native LWC components must be wrapped inside `<div class="slds-scope">` to prevent global style pollution (LWC components are automatically scoped and do not need extra wrapping).
- Standard page skeleton: `slds-page-header` (Header) + `slds-card` (Content block) + right-side `slds-panel` (Related information, optional).

---

## 6. Border Radius & Elevation

- Standard border radius: `0.25rem` (buttons, inputs, cards, badges).
- Elevation (shadow hierarchy, from shallow to deep):
  - Level 1 – Card: `slds-card` built-in shadow
  - Level 2 – Dropdown menu / Popover: `0 2px 3px 0 rgba(0,0,0,.16)`
  - Level 3 – Modal: `0 4px 11px 0 rgba(0,0,0,.16), 0 2px 4px 0 rgba(0,0,0,.12)`
- Do not customize shadow values; prioritize built-in shadows provided by SLDS classes such as `slds-dropdown` and `slds-modal`.

---

## 7. Component Patterns

Principle: **Prioritize official LWC Base Components (`lightning-*`)**; write custom SLDS classes only when official components cannot satisfy requirements.

| Requirement | Preferred Component | Corresponding SLDS Class (for custom reference only) |
|---|---|---|
| Button | `<lightning-button>` / `<lightning-button-icon>` | `slds-button`, `slds-button_brand`, `slds-button_neutral`, `slds-button_destructive` |
| Card Container | `<lightning-card>` | `slds-card` |
| Data Table | `<lightning-datatable>` | `slds-table`, `slds-table_bordered` |
| Form Input | `<lightning-input>`, `<lightning-combobox>`, `<lightning-textarea>` | `slds-form-element` |
| Modal | `<lightning-modal>` (Official LWC Modal API) | `slds-modal`, `slds-backdrop` |
| Badge / Status | `<lightning-badge>` | `slds-badge`, `slds-badge_inverse` |
| Icon | `<lightning-icon>` | See Section 8 |
| Tabs | `<lightning-tabset>` / `<lightning-tab>` | `slds-tabs_default` |
| Progress / Path | `<lightning-progress-indicator>` | `slds-path` |
| Notification Toast | `<lightning-messages>` / Toast Event | `slds-notify_toast` |

**Rules**:

- Opening a Modal inside another Modal is strictly prohibited (explicitly listed as an anti-pattern by Salesforce).
- Table operations (multi-select, sorting, inline editing) must strictly use built-in features of `lightning-datatable`; do not reinvent the wheel.
- Button semantics: `brand` (primary action, only one per page), `neutral` (secondary action), `destructive` (delete / irreversible action).

---

## 8. Icon Guidelines

`<lightning-icon icon-name="utility:xxx" size="small"></lightning-icon>`

- Icon categories: `utility:*` (functional icons, most common), `standard:*` (Salesforce standard object icons), `custom:*` (custom object icons, uploaded in Setup).
- Sizes: `xx-small` (0.75rem) / `x-small` (1rem) / `small` (1.5rem) / `medium` (2rem, default) / `large` (3rem).
- Semantic icons must specify `variant` (e.g., `variant="error"`); do not manually override icon colors.

---

## 9. Accessibility (a11y)

- Adhere to WCAG 2.1 AA; all interactive elements must include `aria-label` or visible text labels.
- Keyboard navigation: Tab order must match the visual reading order; focus must be trapped within a Modal when opened (Focus Trap), and Esc must close it.
- Focus styling must always use the SLDS built-in focus ring (`--slds-g-color-border-brand`); never remove focus outlines with `outline: none`.
- Color must never be the sole means of conveying information (e.g., error states must include an icon or text, not just a red color change).

---

## 10. LWC Coding Conventions

- Component naming: Folder and file names must strictly follow camelCase (e.g., `accountSummaryCard`).
- CSS: Prefer SLDS classes in component `.css` files; when custom styles are needed, use `:host` paired with Styling Hooks (`var(--slds-g-color-brand-base-50)`). Hardcoding hex color codes and using `!important` are prohibited.
- Do not redeclare existing SLDS utility class behaviors to avoid conflicts with future upgrades.
- Every custom component involving data mutation must explicitly handle Loading / Empty / Error states, rendered using corresponding semantic colors and icons.

Example:

```css
/* myComponent.css */
.slds-card {
  border-radius: 0.25rem;
}
.highlight {
  color: var(--slds-g-color-brand-base-50);
}
```

---

## 11. Don'ts

- Do not use any color other than brand blue for primary CTA buttons.
- Do not hardcode hex color codes; always reference them via Styling Hooks or Design Tokens.
- Do not stack Modals on top of other Modals.
- Do not use inline styles to override SLDS component appearances.
- Do not create custom icon sets; prioritize selecting from official SLDS Utility/Standard icons.
- Do not use Simplified Chinese copy or unofficial fonts.

---

## 12. References

- [SLDS Design Tokens | LWC Developer Guide](https://developer.salesforce.com/docs/platform/lwc/guide/create-components-css-design-tokens.html)
- [SLDS Styling Hooks | LWC Developer Guide](https://developer.salesforce.com/docs/platform/lwc/guide/create-components-css-custom-properties.html)
- [Style with Lightning Design System | LWC Developer Guide](https://developer.salesforce.com/docs/platform/lwc/guide/create-components-css-slds.html)
- [Introducing SLDS 2 (Beta) — Release Notes](https://help.salesforce.com/s/articleView?id=release-notes.rn_slds_slds2.htm&language=en_US&release=254&type=5)
- [Design Tokens Use New Salesforce Color System — Release Notes](https://help.salesforce.com/s/articleView?id=release-notes.rn_slds_colors.htm&language=en_US&release=232&type=5)
- [Understanding SLDS 2 — Trailhead](https://trailhead.salesforce.com/content/learn/modules/salesforce-lightning-design-system-2-for-developers/explore-salesforce-lightning-design-system-2)
- [Lightning Design System 2 — Official Color/Typography Page (zeroheight)](https://www.lightningdesignsystem.com/2e1ef8501/p/655b28-color)

**Reminder**: Hex values in this document are derived from publicly compiled SLDS CSS and official documentation. Since Salesforce fine-tunes color system versions quarterly, it is recommended to verify values against the SLDS version in your org (Setup → Themes and Branding) before project go-live to avoid visual inconsistencies caused by version discrepancies.
