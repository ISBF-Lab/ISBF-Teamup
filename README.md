# ISBF Teamup

Independent Discourse plugin for the existing 组队 category. Team-up posts and replies are native Topic/Post records. The ISBF theme renders them with the same feed components used on the home page.

## Configuration

Set `isbf_teamup_category_id` to a real Discourse category ID distinct from the marketplace and learning categories. The plugin does not create or modify a category or its permissions. `0` means unconfigured. `isbf_teamup_enabled` enables the integration; `isbf_teamup_publishing_enabled` controls new topic publishing. Reading, replying, editing and moderation retain Guardian checks.

The native HTML entry route `/isbf/teamup` supports direct requests and refreshes, using native login and category visibility.

## Native contracts

- Create through `POST /posts.json`: a real title and body are required; the internal `[isbf-untitled:…]` placeholder is rejected.
- Optional `isbf_teamup_home` accepts booleans or `"true"`/`"false"`. New topics default to false. Existing topics with no custom field retain their prior home visibility.
- First-post edits use native `PUT /posts/:id.json` and PostRevisor. Home changes are tracked in native revisions; body-only edits preserve the current or missing flag.
- `isbf_teamup` metadata on native topic-list/topic-view/first-post serializers contains `show_on_home`. Site configuration contains `category_id`, `enabled`, `publishing_enabled` and `version: 1`.
- The workbench uses `/filter.json?q=isbf-teamup:all%20order:created`, with native ordering and pagination, login and category access. Only visible topics with a visible, undeleted first post are returned.
- Unfiltered `/latest.json` excludes explicit home opt-outs in SQL before pagination. Category, tag, search and profile lists retain native behavior. The scope composes with ISBF Marketplace's home scope.
- Moving a topic into the team-up category is rejected if it contains anonymous first posts or replies, preserving the original topic and posts.
- Native uploads remain optional and use Discourse's existing upload/composer flow.
- Anonymous first posts and replies are rejected, including per-post anonymous requests, native shadow accounts, and identities exposed by the installed ISBF Anonymous plugin's `User#anonymous?`. Approval rechecks payloads even when Core skips normal validation events.

No Core changes, tables, migrations, upload APIs, image storage, or custom moderation queue are introduced. Discourse decides whether a valid submission needs review. The home flag is retained by native queued-post payloads through approval or rejection.

## Validation

RSpec integration specs run through the official `discourse-plugin.yml` reusable workflow. CI's Core reference must remain an accessible upstream revision compatible with the installed site; local production-only commits cannot be checked out by GitHub CI. Companion-plugin cases run when those plugins are present and otherwise report skips.

Local Ruby syntax: `ruby -c plugin.rb` and each Ruby file under `lib/` and `spec/`. Deployment helper syntax: `bash -n deploy/install-plugin.sh`. These checks do not replace native request specs or browser regression.

## Deployment

Use a reviewed, merged GitHub commit. Main deployment tooling prepares `/shared/isbf-teamup-releases/<commit>/isbf-teamup` inside the existing container; `deploy/install-plugin.sh <commit>` selects it by symlink at `/var/www/discourse/plugins/isbf-teamup`. The script refuses to overwrite a normal plugin directory. Restart/rebuild and site configuration are handled by the coordinator's approved release workflow.

For the initial feature rollback, set `isbf_teamup_publishing_enabled` to false and restore the previous theme with the Teamup visibility safeguards retained (`lib/teamup.js` and the updated recent-discussions code). Keep this plugin enabled, preserve its category setting and all existing home flags, and retain its native list filters. Existing topics, replies, uploads and metadata remain available, and home opt-outs continue to be excluded. This plugin has no schema or upload storage to migrate.