# Tampermonkey remote deployment

This branch hosts a small Tampermonkey loader so browser automation scripts can be edited in GitHub and picked up without copy/paste.

## Architecture

- `loader.user.js`: installed once in Tampermonkey.
- `manifest.json`: list of enabled modules and URL patterns.
- `scripts/*.js`: remote modules loaded only on matching pages.

The loader only accepts module URLs under this repository's trusted `tampermonkey/scripts/` path.

## Install once

Open:

`https://raw.githubusercontent.com/MasterSmalll/yourpods-source/tampermonkey/tampermonkey/loader.user.js`

Tampermonkey should open its installation screen. Approve the installation.

## Adding a module

Create a file under `tampermonkey/scripts/`, then add an entry to `manifest.json`:

```json
{
  "id": "example",
  "enabled": true,
  "version": "1",
  "matches": ["https://example.com/*"],
  "source": "https://raw.githubusercontent.com/MasterSmalll/yourpods-source/tampermonkey/tampermonkey/scripts/example.js"
}
```

A module receives a `context` object:

```js
const { window, document, location, console } = context;
```

## Security

Do not put passwords, API keys, cookies, session tokens, or private data in this public branch. Keep secrets in local browser storage or a private backend.
