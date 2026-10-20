# TvCord security setup

These are the security features implemented in the repository, plus the external setup required to use them. GitHub Pages cannot keep service-role keys or Discord webhook URLs secret.

## 1. Apply the database migration

In Supabase Dashboard, open **SQL Editor**, paste and run **supabase/attachments-reports-admin.sql**.

Run it after the main schema and social/friendship schema are installed. The migration sets the attachment bucket's maximum object size to **50 MiB (52,428,800 bytes)** and restricts accepted MIME types. It also adds server-side checks for message sender identity, server membership, account restrictions, and a basic obvious-keyword filter.

If your project has not already run **supabase/launch-safety.sql**, run that too. The attachment migration is designed to be rerunnable. Check the SQL Editor result for errors; do not assume a migration applied if it reports a failure.

## 2. Deploy Edge Functions and configure secrets

Install/use the Supabase CLI, log in, link this project, and deploy both functions from the repository root:

    supabase login
    supabase link --project-ref dbiinubzfmsqlzngrjoc
    supabase functions deploy report-to-discord
    supabase functions deploy admin-ban

Set the Discord webhook only as an Edge Function secret (never put it in index.html):

    supabase secrets set DISCORD_WEBHOOK_URL="YOUR_PRIVATE_DISCORD_MODERATION_WEBHOOK"
    supabase secrets set TVCORD_ADMIN_USER_IDS="YOUR-ADMIN-USER-UUID"

For multiple administrators, put their UUIDs in the same secret separated by commas. Obtain the UUID from the signed-in account's Supabase Auth user record. Treat the webhook URL as a password: anyone who gets it can post to that Discord channel.

Supabase provides the function URL, anon key, and service-role key to deployed Edge Functions. Never put the service-role key into GitHub Pages.

## 3. What is implemented

- Attachments are restored for images/GIFs, PDF, plain text, and ZIP files, with a browser-side 50 MB limit and a storage-bucket 50 MiB limit after the SQL migration.
- Reports are stored in public.content_reports. The Edge Function verifies the signed-in reporter and forwards the report, reporter ID, reported user ID, message ID/text, channel ID, reason/details, and attachment URL/name to Discord.
- The admin panel checks the signed-in UUID against the server-side TVCORD_ADMIN_USER_IDS secret. It can apply/remove Supabase Auth bans and database restrictions by user UUID.
- Public profile cards show username, status, profile picture, banner, and public account UUID.
- Theme presets are available: Midnight, Rose, Ocean, Forest, Amethyst, and Sunset.

## 4. Safety limits that matter

This is a meaningful baseline, not a guarantee of complete protection. The text filter is not a full porn detector and can be bypassed. The site does not yet have a trusted server-side image/video classifier, malware scanner, human moderation queue, or reliable automated-pedophile detection. A reported attachment URL is sent to the configured moderation Discord channel; the function does not independently classify the image. Configure a reputable moderation/scanning provider and human review before opening the site to the public.

The current attachment bucket remains public for compatibility with the existing client, so anyone with a file URL can view it. Do not upload private or sensitive files. For stronger privacy, move attachments to a private bucket and issue short-lived signed URLs after membership checks.

Enable email confirmation and CAPTCHA/bot protection in Supabase Auth settings. Configure abuse alerts and review reports frequently. A browser-only client cannot reliably prevent self-bots or multi-accounting by itself.
