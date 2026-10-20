# TvCord security setup

These are the security features implemented in the repository, plus the external setup required to use them. GitHub Pages cannot keep service-role keys or Discord webhook URLs secret.

## 1. Apply the database migration

In Supabase Dashboard, open **SQL Editor**, paste and run **supabase/attachments-reports-admin.sql**.

Run the main schema and social/friendship schema first, then run **supabase/launch-safety.sql** if needed, and run **supabase/attachments-reports-admin.sql last**. Do not rerun schema.sql or launch-safety.sql afterward without rerunning the attachment migration, because those older files set smaller upload limits. The migration sets the attachment bucket's maximum object size to **50 MiB (52,428,800 bytes)** and restricts accepted MIME types. It also adds server-side checks for message sender identity, server membership, account restrictions, and a basic obvious-keyword filter. The attachments bucket accepts any MIME type, but every upload still must pass server-side scanning; images are checked with Google Cloud Vision and all other file types require a compatible malware scanner. The maximum remains 50 MiB.

If your project has not already run **supabase/launch-safety.sql**, run that too. The attachment migration is designed to be rerunnable. Check the SQL Editor result for errors; do not assume a migration applied if it reports a failure.

## 2. Deploy Edge Functions and configure secrets

Install/use the Supabase CLI, log in, link this project, and deploy both functions from the repository root:

    supabase login
    supabase link --project-ref dbiinubzfmsqlzngrjoc
    supabase functions deploy report-to-discord
    supabase functions deploy admin-ban
    supabase functions deploy moderate-attachment
    supabase functions deploy attachment-url

Set the Discord webhook only as an Edge Function secret (never put it in index.html):

    supabase secrets set DISCORD_WEBHOOK_URL="YOUR_PRIVATE_DISCORD_MODERATION_WEBHOOK"
    supabase secrets set TVCORD_ADMIN_USER_IDS="YOUR-ADMIN-USER-UUID"
    supabase secrets set GOOGLE_CLOUD_VISION_API_KEY="YOUR_GOOGLE_VISION_API_KEY"
    supabase secrets set TVCORD_FILE_SCANNER_URL="YOUR_TRUSTED_SCANNER_ENDPOINT"
    supabase secrets set TVCORD_FILE_SCANNER_TOKEN="YOUR_PRIVATE_SCANNER_TOKEN"

For multiple administrators, put their UUIDs in the same secret separated by commas. Obtain the UUID from the signed-in account's Supabase Auth user record. Treat the webhook URL as a password: anyone who gets it can post to that Discord channel.

Supabase provides the function URL, anon key, and service-role key to deployed Edge Functions. Never put the service-role key into GitHub Pages.

## 3. What is implemented

- Attachments accept any file type, with a browser-side 50 MB limit and a storage-bucket 50 MiB limit after the SQL migration. This does not mean every file will be accepted: all uploads must pass server-side scanning. The bucket is private; attachment URLs are short-lived signed URLs returned only to server members.
- Images are fail-closed through Google Cloud Vision SafeSearch before they can be attached to a message. Configure a Google Cloud Vision API key with SafeSearch enabled. For every non-image file type, configure a trusted malware-scanning endpoint that accepts raw bytes and returns JSON `{ "clean": true }` only for a clean file. If either scanner is missing or fails, the upload is rejected.
- The database trigger refuses to publish an attachment unless the Edge Function has recorded a successful server-side scan verdict.
- Reports are stored in public.content_reports. The Edge Function verifies the signed-in reporter and forwards the report, reporter ID, reported user ID, message ID/text, channel ID, reason/details, and attachment URL/name to Discord.
- The admin panel checks the signed-in UUID against the server-side TVCORD_ADMIN_USER_IDS secret. It can apply/remove Supabase Auth bans and database restrictions by user UUID.
- Public profile cards show username, status, profile picture, banner, and public account UUID.
- Theme presets are available: Midnight, Rose, Ocean, Forest, Amethyst, and Sunset.

## 4. Safety limits that matter

This is a meaningful baseline, not a guarantee of complete protection. Google Vision SafeSearch is a useful image classifier but is not a complete detector for grooming, exploitation, or every unsafe image/video. It does not inspect videos, and it is not a substitute for human review. The configured malware scanner endpoint must accept the uploaded file bytes as the raw POST body, receive `Authorization: Bearer <TVCORD_FILE_SCANNER_TOKEN>`, `Content-Type`, `X-Filename`, and `X-Expected-Size` headers, and return JSON `{ "clean": true }` only after a successful malware scan. Any timeout, error, or unknown verdict blocks the upload. Google Vision image requests over 18 MiB are blocked by this implementation; the overall storage limit remains 50 MiB for supported file types. No automated tool can guarantee detection of every offender or harmful item; keep a staffed moderation process and promptly escalate child-safety reports.

The attachment bucket is private. The `attachment-url` Edge Function issues short-lived signed URLs only after checking server membership. Do not add a public-read policy for the attachments bucket.

Enable email confirmation and CAPTCHA/bot protection in Supabase Auth settings. Configure abuse alerts and review reports frequently. A browser-only client cannot reliably prevent self-bots or multi-accounting by itself.
