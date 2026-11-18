# ChatGPT integration verification

In AI settings, users choose ChatGPT, Custom API, or Apple Intelligence for both lookup and card prefill. The selected service determines credentials and billing; failures never trigger an automatic switch. The ChatGPT option implements OpenAI's [open-source ChatGPT plan usage](https://developers.openai.com/siwc/token-sharing-open-source) flow. Release it under a suitable open-source license and confirm eligibility before distribution. Paid or remotely hosted offerings require separate review. Plus/Pro subscriptions remain subject to account, workspace, region, and application restrictions.

Custom API services do not require ChatGPT sign-in. Custom API presents one connection form for remote or local Chat Completions-compatible services, with an address, optional API key, and a single left-aligned native model control. Former Local Models entries use this same page; their persisted kind remains readable and their IDs, credentials, cached models, and active selection are preserved. An empty key selects no authentication; a supplied key uses Bearer authentication. The model menu contains explicit catalog fetching and manual model ID entry; opening the page does not fetch the catalog. Empty or failed catalogs preserve the existing list; manual IDs join the cache. Existing multiple-profile storage is preserved for compatibility, with the active compatible profile preferred for editing, otherwise the first compatible profile. API-key credentials stay in Keychain; configurations with no authentication omit the Authorization header and skip their profile credential storage. Existing API settings migrate automatically while retaining the original Keychain entry. Lookup and card recovery actions open the shared **AI Settings** entry. Changing the selected service or its configuration cancels pending results, and resuming prefill preserves manually entered meanings.

The ChatGPT integration uses dynamic public-client registration, PKCE S256, state, nonce, a loopback callback bound only to `127.0.0.1`, and RS256 ID-token validation against OpenAI's JWKS. No developer API key or client secret is shipped. Each account's issued client ID and credentials stay together in Keychain. Opaque host IDs and nonsecret service/UI preferences go into UserDefaults. Request and authorization URLs, tokens, codes, and server bodies must not be added to logs or analytics.

For ChatGPT, model choices come from the signed-in account's official model catalog. The app sends text-only Responses requests with `store: false` and `stream: true`; it does not request tools or server conversation storage. Only `response.completed` commits a result. Truncated streams and failures after partial text are not saved as meanings.

Refreshes are serialized per client registration and rotating credentials are persisted even if the UI switches accounts. A switched or signed-out account cannot publish an old result or retry an old request against another account. Temporary network/service errors retain credentials. Terminal refresh failures require another login. The connected account page has only Sign out and Test actions. Connection followed by a successful initial test, or a successful explicit Test for an existing candidate, activates ChatGPT without a Save button. Retesting the current account keeps its production session intact. The Test row uses only a spinner or a colored Service available / Service unavailable result; it does not expose detailed errors. Sign-out attempts remote revocation and clears the local account; the settings page does not show additional revocation-status text.

Run the focused automated checks:

```sh
swift test --filter 'ChatGPT|AIServiceTests|AISettingsRoutingTests'
zsh Scripts/build-app.sh
```

Automated tests use synthetic credentials, signed test identities, mocked network replies, and a local loopback callback. They do not verify live OpenAI account eligibility or spend a real subscription's allowance.

If browser sign-in returns but the app cannot verify it, inspect macOS unified logs for subsystem `com.readingtool.daily` and category `ChatGPTAuth`. Authentication diagnostics contain fixed stage/reason codes and HTTP status values only. They never include callback URLs, authorization codes, tokens, response bodies, or identity claim values. The browser callback page acknowledges receipt; only the app can confirm that token exchange, identity validation, and connection have succeeded.

An `invalid_grant` during authorization-code exchange starts at most one fresh browser authorization using the issued client ID retained only for that attempt. The retry generates new state, nonce, PKCE values, and a new loopback listener; it never replays the rejected code. Repeated rejection gets an authorization-specific message. Refresh-token `invalid_grant` still requires explicit sign-in. An authorization-code rejection alone is not proof of subscription ineligibility; the official plan-usage flow is intended for eligible Plus/Pro accounts.

Before releasing, use an eligible account to verify:

- First browser login and consent return to the app, pick a model automatically, and enable both Ask AI and card prefill.
- Restart preserves the selected account; an expired access token renews automatically, while terminal authorization expiry asks for sign-in.
- Declining plan consent leaves a clear action to enable plan access. Cancelling or timing out does not discard an existing working account.
- Switching accounts during an explanation never shows a stale result in the new account, and each account retains its own registration.
- Without ChatGPT sign-in, a saved custom API service supports lookup and prefill. Switching services discards pending results, and saving a configuration resumes unconfigured prefill without replacing manual text.
- Usage limits, credits, ineligible accounts, revoked access, offline networking, service errors, and interrupted streams produce brief recovery messages; partial meanings never overwrite a card.
- Signing out stops requests and clears local tokens for that account, including when remote revocation cannot be confirmed. Signing out a pending candidate does not remove the prior production account.

The current upstream protocol is a preview. Follow the official [sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [limits](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations), and [error recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery) documentation when updating this integration.
