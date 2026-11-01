# Training Database Drift Assessment

Date: 2026-10-31
Repository branch: `accounting-upgrade-dev`
Training project: `mqnbifhhdhauuaqkvhbk`

## Summary

The current training Supabase project is not a complete schema mirror of the repository's current migration set. It is useful for isolated schema checks, but it is not yet a reliable integration-test target for the current application.

No migrations or schema changes were applied during this assessment.

## Evidence

- The repository contains 214 SQL migration files under `supabase/migrations`.
- The training database reports 75 applied migration-history entries, many with training-specific names and duplicate imported baseline entries.
- Comparing exact migration names after removing the `training_` prefix shows 147 repository migration filenames not represented in the training migration history. This is a filename comparison, not proof that every one of those migrations is absent from the schema; some changes may have been imported under other names.
- The current frontend calls `dv_accounting_get_my_permissions()` on sign-in. That function was not found in the training database.
- The repository migration `0030_granular_permissions.sql` defines the granular permission catalog, role rules, per-user overrides and the `dv_accounting_get_my_permissions()` RPC. The training database instead exposes a coarser `dv_accounting_role_permissions` table with JSON module-level settings. The granular permission objects required by the current frontend are therefore not verified in training.
- The frontend in `src/App.jsx` directly accesses more than 50 tables/views and calls 22 distinct RPCs. The full dependency list must be reconciled with migration history before changing policies or function grants.

## Why this matters

Applying a security migration to this training project now could produce misleading results: a policy may refer to tables or permission functions that do not exist, and a test may pass or fail against a schema that differs from the app's actual target schema. Replaying all repository migrations blindly is also unsafe because the repository contains duplicate migration-number prefixes, overlapping historical repairs and migrations with data backfills or workflow-specific side effects.

## Required next step

1. Reconcile the repository migration sequence against the production schema metadata without changing production.
2. Build a clean test database from the exact current migration set, or deliberately bring the training database forward using a reviewed, ordered migration plan.
3. Confirm the expected permission tables, RPCs, storage policies, views and frontend table dependencies exist.
4. Run the current application build and database tests against that aligned schema.
5. Only then begin role-scoped RLS replacement and RPC authorization changes in small groups.

## Safety rule

Do not treat the current training database as an authoritative replica of production. Do not run the entire migration directory against it as a batch. Do not change production or attempt to merge any training schema changes into production until the migration sequence and data effects have been reviewed.
