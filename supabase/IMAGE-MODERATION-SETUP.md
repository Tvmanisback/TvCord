# TvCord server-side moderation setup

This setup keeps moderation on the backend:
- Text messages are checked by the PostgreSQL trigger in `message-moderation.sql`.
- Images are checked by the `moderate-attachment` Supabase Edge Function using the Hugging Face `Falconsai/nsfw_image_detection` classifier.
- Non-image attachments are deliberately accepted without content or malware scanning, as requested.

## 1. Enable text moderation

Open Supabase Dashboard → SQL Editor. Run the contents of [message-moderation.sql](./message-moderation.sql).

The trigger is the enforcement point for messages inserted through Supabase, not just the website. It uses simple rules and is not a complete AI text moderator.

## 2. Add the image classifier token

The backend needs a Hugging Face access token with **Make calls to Inference Providers** permission. Create a fine-grained token in your Hugging Face account settings. Do not put it in `index.html`, GitHub Pages, or a public repository.

In Supabase Dashboard, open **Edge Functions → Secrets** (or the project's function secrets settings) and add:

- Name: `HF_TOKEN`
- Value: your Hugging Face token

Inference availability and free usage allowances can be limited. If the provider quota runs out or the service is unavailable, TvCord intentionally blocks image uploads rather than silently skipping moderation. This integration does not promise unlimited free inference.

## 3. Deploy the Edge Functions

Deploy the latest code from this repository:
- `supabase/functions/moderate-attachment/index.ts`
- `supabase/functions/attachment-url/index.ts`

The first function performs server-side image moderation and records the approval verdict. The second creates access-controlled signed attachment URLs. GitHub commits alone do not deploy Supabase Edge Functions; make sure the deployed function code matches this repository.

Keep `verify_jwt = true` for both functions in `supabase/config.toml`.

## 4. Confirm the attachment database setup

The private `attachments` bucket and `attachment_scan_results` table must exist. If they do not, review and run `attachments-reports-admin.sql` after the other required schema migrations. Do not run older bucket setup SQL after this migration, because it can overwrite the 50 MiB bucket configuration.

## 5. Expected behavior

- Images: up to 18 MiB, format checked and sent to the server-side classifier.
- Non-image files: up to 50 MiB, accepted without content or malware scanning.
- If the image provider, token, or moderation database write fails, the image upload is rejected with an explanatory message.
- Moderation can miss explicit content or flag harmless images. The model is a safety layer, not a guarantee.
