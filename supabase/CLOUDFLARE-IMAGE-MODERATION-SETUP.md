# TvCord Cloudflare Image Moderation Setup

TvCord's `moderate-attachment` Edge Function now uses Cloudflare Workers AI instead of Hugging Face for image screening.

## 1. Create Cloudflare Workers AI credentials

1. Sign in to the [Cloudflare dashboard](https://dash.cloudflare.com/).
2. Open **Workers AI** and choose **Use REST API**.
3. Create a Workers AI API token using Cloudflare's provided token template, or create a token with the required Workers AI permissions.
4. Copy the token and your Cloudflare **Account ID**. Keep the token private.

Cloudflare's current instructions: https://developers.cloudflare.com/workers-ai/get-started/rest-api/

The function uses the vision model `@cf/meta/llama-3.2-11b-vision-instruct`. Cloudflare may require accepting the model's license the first time it is used; the function attempts that if the provider explicitly reports a license/acceptance error.

## 2. Add Supabase Edge Function secrets

Open the [TvCord Supabase Edge Functions dashboard](https://supabase.com/dashboard/project/dbiinubzfmsqlzngrjoc/functions) and open the Edge Function secrets/settings area. Add these exact secrets:

- `CLOUDFLARE_ACCOUNT_ID` — your Cloudflare account ID
- `CLOUDFLARE_API_TOKEN` — your Cloudflare Workers AI API token

Do not put these credentials in `index.html`, GitHub Pages, or any public file. Remove the old `HF_TOKEN` secret after Cloudflare moderation is deployed and tested.

## 3. Deploy the updated Edge Function

The GitHub commit does not automatically deploy to Supabase unless you have a deployment workflow configured.

Deploy the latest version of `supabase/functions/moderate-attachment/index.ts` from this repository to the Supabase project. You can use your existing Supabase CLI deployment workflow, or copy the committed function into the Supabase function editor if your dashboard supports editing and deployment there.

Function source: https://github.com/Tvmanisback/TvCord/blob/main/supabase/functions/moderate-attachment/index.ts

## 4. Test before relying on it

1. Try a small, ordinary image in a private test channel.
2. Check the `moderate-attachment` logs in Supabase.
3. Confirm that an image gets an approval only when the model returns the exact word `SAFE`.
4. Confirm that provider errors or unclear responses block the upload rather than bypassing screening.

## Important limits

- TvCord's general attachment size limit remains 50 MiB.
- The current Cloudflare vision request path only sends images up to 8 MiB for screening. Larger images are blocked with an explanation and need to be compressed before uploading. Non-image files continue to be accepted without content scanning, as requested.
- This is AI-based screening, not a guarantee. It can miss inappropriate content or incorrectly block harmless images. Keep user reporting and moderation review enabled.
- Workers AI usage and quotas can change. Check Cloudflare's dashboard and current pricing; do not assume unlimited free usage.
- Do not disable fail-closed behavior when the provider is unavailable.
