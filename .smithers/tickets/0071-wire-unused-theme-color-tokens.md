# Wire Unused Theme Color Tokens

## Problem

Several theme color tokens are defined but never referenced, while some
views use hardcoded colors instead of theme tokens.

Review: ui_build_theme.

## Current State

- Color tokens exist in the asset catalog or theme definition but are unused.
- Some views use literal colors.

## Proposed Changes

- Replace hardcoded colors with the appropriate theme tokens.
- Remove any truly unused tokens.

## Files

- Theme/asset files
- View files with hardcoded colors

## Acceptance Criteria

- All views use theme color tokens instead of hardcoded values.
- No orphaned, unused color tokens remain.
