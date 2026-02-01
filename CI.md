# Wofi - CI/CD Deployment Guide

This guide explains how to set up automated releases to CurseForge (and optionally WoWInterface/Wago) using GitHub Actions.

## Overview

The recommended tool is [BigWigsMods/packager](https://github.com/marketplace/actions/wow-packager) - a GitHub Action that automatically:
- Packages your addon into a distributable zip
- Detects version from Git tags
- Generates changelogs from commits
- Uploads to CurseForge, WoWInterface, and Wago

## Setup Instructions

### 1. Get Your CurseForge Project ID

1. Go to your addon page on CurseForge
2. Look in the "About Project" section on the right sidebar
3. Find the **Project ID** (a number like `123456`)

### 2. Generate a CurseForge API Token

1. Go to: https://authors-old.curseforge.com/account/api-tokens
2. Click "Generate Token"
3. Copy the token (you won't see it again!)

### 3. Add Secrets to GitHub Repository

1. Go to your repo on GitHub
2. Navigate to **Settings → Secrets and variables → Actions**
3. Add these repository secrets:
   - `CF_API_KEY` — Your CurseForge API token
   - `CURSEFORGE_PROJECT_ID` — Your addon's project ID

### 4. Create the GitHub Actions Workflow

Create file `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Needed for changelog generation

      - name: Package and Release
        uses: BigWigsMods/packager@v2
        with:
          args: -p ${{ secrets.CURSEFORGE_PROJECT_ID }}
        env:
          CF_API_KEY: ${{ secrets.CF_API_KEY }}
          GITHUB_OAUTH: ${{ secrets.GITHUB_TOKEN }}
```

### 5. Create a .pkgmeta File (Optional)

Create `.pkgmeta` in your repo root to customize packaging:

```yaml
package-as: Wofi

ignore:
  - README.md
  - CHANGELOG.md
  - .github
  - .gitignore
  - "*.md"
```

## How to Release

1. **Update your version** in `Wofi.toc`:
   ```
   ## Version: 1.0.1
   ```

2. **Update CHANGELOG.md** with the new version's changes

3. **Commit your changes**:
   ```bash
   git add .
   git commit -m "chore: bump version to 1.0.1"
   ```

4. **Create and push a tag**:
   ```bash
   git tag v1.0.1
   git push origin main --tags
   ```

5. The GitHub Action will automatically:
   - Package your addon
   - Create a GitHub Release
   - Upload to CurseForge

## Adding WoWInterface and Wago (Optional)

To also upload to WoWInterface and Wago, add more secrets and update the workflow:

**Additional Secrets:**
- `WOWI_API_TOKEN` — WoWInterface API token
- `WOWI_ADDON_ID` — WoWInterface addon ID
- `WAGO_API_TOKEN` — Wago API token
- `WAGO_PROJECT_ID` — Wago project ID

**Updated Workflow:**
```yaml
- name: Package and Release
  uses: BigWigsMods/packager@v2
  with:
    args: >-
      -p ${{ secrets.CURSEFORGE_PROJECT_ID }}
      -w ${{ secrets.WOWI_ADDON_ID }}
      -a ${{ secrets.WAGO_PROJECT_ID }}
  env:
    CF_API_KEY: ${{ secrets.CF_API_KEY }}
    WOWI_API_TOKEN: ${{ secrets.WOWI_API_TOKEN }}
    WAGO_API_TOKEN: ${{ secrets.WAGO_API_TOKEN }}
    GITHUB_OAUTH: ${{ secrets.GITHUB_TOKEN }}
```

## Game Version Detection

The packager automatically detects game versions from your `.toc` file's `## Interface:` line:
- `20505` → TBC Classic / Anniversary Edition
- `11503` → Classic Era
- `110002` → Retail

## Resources

- [BigWigsMods/packager Documentation](https://github.com/BigWigsMods/packager)
- [WoW Packager GitHub Action](https://github.com/marketplace/actions/wow-packager)
- [CurseForge API Tokens](https://authors-old.curseforge.com/account/api-tokens)
- [Blizzard Forum Guide](https://us.forums.blizzard.com/en/wow/t/creating-addon-releases-with-github-actions/613424)
