# Proxy panel and Google Search

September 20, 2026

## Panel copy and status

The proxy panel now uses “Use HTTP proxy” and “Browse the Internet Archive” checkboxes. The date retains its own label. “Uses the closest available capture.” appears only when archive browsing is selected. The panel has no permanent Status row; a small spinner and short message appear while changes are pending. A failure offers “Couldn’t update the proxy. Try again.” instead of displaying raw command output. Technical errors remain in Device Logs. An open panel receives status updates rather than showing the value from when it opened.

Archive dates are edited as local calendar days while preserving the eight-digit archive request value. Previously, a UTC-midnight date looked correct in the picker but AppKit's accessibility value described the previous evening in New York. Display, accessibility and serialization now agree, including across daylight-saving changes.

This applies [clean-copy](https://paste.rachel.systems/ukogokijaz.md) and the supplied 2014 OS X Human Interface Guidelines, “Use User-Oriented Terminology” and “Create Succinct Labels for UI Elements,” pages 44–46.

| Previous copy | Change | Reason |
| --- | --- | --- |
| “HTTP Proxy connects through your Mac. Choose an optional date to browse pages preserved by the Internet Archive. Everything runs inside Light Touch; archived pages use the closest available capture.” | Cut the paragraph. Name the archive in the checkbox; show the closest-capture fact beside an enabled date. | Most of it repeats the controls or explains implementation. |
| “Proxy” beside a No Proxy / HTTP Proxy pop-up | “Use HTTP proxy” checkbox | Two states need one direct choice. |
| “Browse an archived date” | “Browse the Internet Archive” | Names the source rather than implying that every requested date exists. |
| “Status: Off — previous device settings restored” / “Status: Active” | Cut during normal operation. | Repeats the current choice and describes internal cleanup. |
| Raw helper/SSH error output | “Couldn’t update the proxy. Try again.” | Gives an action; keeps diagnostics in the log. |

## Google Search: upstream legacy-browser rejection

The reported Google 403 is reproducible outside the emulator with iOS 3.1.3 Safari’s user agent:

```
Mozilla/5.0 (iPod; U; CPU iPhone OS 3_1_3 like Mac OS X; en-us) AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7E18 Safari/528.16
```

The request was `www.google.com/search?q=light+touch&ie=UTF-8&oe=UTF-8&client=safari`. Direct requests over both HTTP and HTTPS, with HTTP/1.0 and HTTP/1.1, returned Google's own HTTP 403 and “Your client does not have permission” page. The native proxy helper produces the same response. The Google home page returned 200 with the same user agent, so DNS and the connection itself worked.

Removing the old Safari parameters did not change the result. The legacy `/m/search`, `/xhtml/search`, `/xhtml` paths and `gbv=1`, `udm=14`, and `ucbcb=1` options also returned 403. A current Safari user agent returned 200, but its body was a modern JavaScript challenge rather than search results. Replacing the user agent would therefore hide the error without establishing usable search in iOS 3 WebKit.

Google's [Search guidance](https://support.google.com/websearch/answer/16515119?hl=en) calls for an up-to-date browser; its [JavaScript-required page](https://www.google.com/httpservice/retry/enablejs) is part of the current Search flow. The specific legacy-browser rejection above is an observed result, not a claim that Google documents that exact user-agent rule. Responses may vary by region and change over time.

No query rewriting, search-provider substitution, user-agent spoofing, or fabricated result page was added. Google Search remains an external compatibility limitation. The local HTTP/TLS bridge can modernize transport; it does not replace the guest’s JavaScript engine.

## Verification

- `python3 tests/check-proxy-panel.py`: real AppKit controls, archive-date preservation and day stepping in New York, Los Angeles and Tokyo time, pending/failure/ready transitions, and dynamic alert sizing in all three modes. The date check fails against the previous UTC picker implementation.
- `python3 tests/check-web-proxy-forwarding.py`: native C helper with an isolated local origin, proving that the URL, legacy user agent, HTTP 403 status, and response body survive forwarding unchanged, alongside a successful response.
- Live request evidence is saved in `/tmp/ltm-google-*.txt` on the development machine. These raw, time-dependent responses are not bundled into the app.
