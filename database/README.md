# Paperwork Library database setup

Before deploying the Document Library and library-connected Paperwork Validation UI, run `paperwork_library_setup.sql` in the Supabase SQL Editor for the **DV-Back-Office** project.

The setup creates:

- `public.dv_accounting_paperwork_library` for official reference form metadata, versions, and JSON validation rules.
- The private `dv-paperwork-reference` Storage bucket for official blank PDF forms.
- Row Level Security policies that let authenticated agents read published reference forms while restricting uploads, edits, publishing, and archiving to authorized management roles.

The SQL script does not upload any forms or completed agent paperwork. Administrators add official blank reference forms through the Document Library after the schema and bucket are in place.

If the project has additional Data API schema restrictions, confirm that the public schema and authenticated role are enabled for this table in the Supabase Data API settings. The SQL script includes the required table grants and RLS policies.
