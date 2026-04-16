---
name: nazgul:docs
description: View, generate, or regenerate project documents (PRD, TRD, ADRs, test plans). Use when asked about project documentation, design decisions, or technical specs.
context: fork
allowed-tools: Read, Write, Glob, Grep, Bash
metadata:
  author: Jose Mejia
  version: 1.2.2
---

# Nazgul Docs

## Examples
- `/nazgul:docs` — View list of generated documents
- `/nazgul:docs generate` — Generate or regenerate all project documents
- `/nazgul:docs approve` — Approve documents for planning

## Current Documents
- Manifest: !`cat nazgul/docs/manifest.md 2>/dev/null || echo "No documents generated yet. Run /nazgul:init first."`
- Classification: !`cat nazgul/context/project-classification.md 2>/dev/null || echo "Project not classified yet."`
- Config: !`jq '.documents' nazgul/config.json 2>/dev/null || echo "No document config found."`

## Arguments
$ARGUMENTS

## Instructions

Format all output per `references/ui-brand.md` — use stage banners, status symbols, and display patterns defined there.

Based on the user's request:

### View Documents
If the user wants to see existing documents:
1. Read `nazgul/docs/manifest.md` for the document list
2. Read the requested document from `nazgul/docs/`
3. Display a formatted summary

### Generate Documents
If the user wants to generate or regenerate documents:
1. Read `nazgul/context/project-classification.md` for project type
2. Delegate to the doc-generator agent
3. The doc-generator will use templates from `templates/docs/` and write to `nazgul/docs/`
4. Update `nazgul/docs/manifest.md`

### Approve Documents
If the user wants to approve documents for planning:
1. Update the document status in `nazgul/docs/manifest.md` to "approved"
2. Update `nazgul/config.json -> documents.approved` array
3. Confirm which documents were approved
