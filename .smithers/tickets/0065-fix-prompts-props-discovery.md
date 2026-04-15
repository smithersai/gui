# Fix Prompts Props Discovery Not MDX-Aware

## Problem

The prompt props discovery logic does not parse MDX frontmatter or component
props, so prompts using MDX features show no configurable props.

Review: prompts.

## Current State

- Props are extracted from plain template syntax only.

## Proposed Changes

- Add MDX frontmatter parsing (YAML between `---` delimiters).
- Extract props from MDX component usage patterns.

## Files

- Prompts view/logic files

## Acceptance Criteria

- MDX frontmatter props are discovered and displayed.
- Both template and MDX prop styles are supported.
