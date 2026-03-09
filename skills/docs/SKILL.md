---
name: docs
description: View, generate, or regenerate project documents (PRD, TRD, ADRs, test plans). Use when asked about project documentation, design decisions, or technical specs.
context: fork
allowed-tools: Read, Write, Glob, Grep, Bash
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Hydra Docs

## Examples
- `/hydra:docs` — View list of generated documents
- `/hydra:docs generate` — Generate or regenerate all project documents
- `/hydra:docs approve` — Approve documents for planning

## Current Documents
- Manifest: !`cat hydra/docs/manifest.md 2>/dev/null || echo "No documents generated yet. Run /hydra:init first."`
- Classification: !`cat hydra/context/project-classification.md 2>/dev/null || echo "Project not classified yet."`
- Config: !`jq '.documents' hydra/config.json 2>/dev/null || echo "No document config found."`

## Arguments
$ARGUMENTS

## Instructions

Based on the user's request:

### View Documents
If the user wants to see existing documents:
1. Read `hydra/docs/manifest.md` for the document list
2. Read the requested document from `hydra/docs/`
3. Display a formatted summary

### Generate Documents
If the user wants to generate or regenerate documents:
1. Read `hydra/context/project-classification.md` for project type
2. Delegate to the doc-generator agent
3. The doc-generator will use templates from `templates/docs/` and write to `hydra/docs/`
4. Update `hydra/docs/manifest.md`

### Approve Documents
If the user wants to approve documents for planning:
1. Update the document status in `hydra/docs/manifest.md` to "approved"
2. Update `hydra/config.json -> documents.approved` array
3. Confirm which documents were approved
