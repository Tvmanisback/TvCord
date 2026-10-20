# TvCord: one-time project setup

This file is for the person configuring the project. End users can read README.md.

## 1. Create the Supabase project

1. Create a project at https://supabase.com.
2. Open SQL Editor and run the entire supabase/schema.sql file.
3. Open Project Settings → API and copy the Project URL and anon/public key.
4. Edit public/config.js and replace the example URL and key with those values. The anon/public key is intended for browser use; never put a service-role key in this file.
5. In Authentication → URL Configuration, add https://tvmanisback.github.io/TvCord/ as a Site URL / allowed redirect URL. If you test locally, add the local URL as well.

## 2. Enable GitHub Pages

1. Open the TvCord repository settings on GitHub.
2. Go to Pages and set the publishing source to GitHub Actions.
3. Ensure the default branch is main.
4. Commit and push the project files to main, or use Actions → Deploy TvCord to GitHub Pages → Run workflow.
5. Wait for the workflow to finish, then visit https://tvmanisback.github.io/TvCord/.

The workflow installs dependencies, builds Vite's static output, and deploys dist/ to GitHub Pages. No Vercel or always-on local computer is involved.

## 3. Verify the first run

- Open the site in a private browser window.
- Create a test account and confirm email if required.
- Create a server, post a message, then open the site in another test account and join with the invite code.
- Confirm the new message appears without refreshing.
- Test an avatar and an image attachment.
- Check the Supabase Authentication, Database, and Storage logs if anything fails.

## Notes and current scope

- GitHub Pages is a static host; Supabase handles authentication, database access, realtime subscriptions, and file storage.
- public/config.js is public. Only put the Supabase project URL and anon/public key there. Security depends on the SQL policies, not hiding the anon key.
- The current UI implements server/channel chat, invite codes, member lists, profile name/status/accent, avatar uploads, and attachments. It does not yet implement direct-message conversations, message editing/deletion UI, live voice, server banners, or profile-theme controls even though some related schema fields or UI concepts exist.
- The initial attachment limit is 25 MiB; avatar uploads are limited to 10 MiB. Adjust bucket limits in Supabase and update the client-side limit together if you change them.
- The UI has a placeholder section for voice channels, but no voice transport has been built. Do not advertise voice calling as available.
- The database uses public media buckets for simple image display. Uploaded media URLs can be opened by anyone who has the URL, so don't use these buckets for private files.
