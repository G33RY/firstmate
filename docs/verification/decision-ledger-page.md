# Decision-ledger page verification

Audience: maintainer verification.

`bin/fm-decision-ledger-page.sh` updates a project's published decision-ledger page in
place through the ht-ml.app API directly, because the `lavish-axi share` CLI command only
creates a new page (`POST /v1/sites`) and has no update subcommand. This record is the
evidence that the underlying API accepts an authenticated in-place update on the same URL,
and that a password set at creation survives an update that does not resend it.

Verified live on 2026-09-04 against `https://api.ht-ml.app`.

## Create, then update in place

```sh
curl -sS -X POST https://api.ht-ml.app/v1/sites -H 'content-type: application/json' \
  -d '{"html_content":"<html><body><h1>v1</h1></body></html>"}' -w '\nHTTP_STATUS:%{http_code}\n'
```

```text
{"site_id":"1e632471","update_key":"YZt4WHGKIEb7FeMrGlKo2dWCCsV9w9DrBM7ORf-vHlc","status":"active","url":"https://1e632471.ht-ml.app/","message":null}
HTTP_STATUS:200
```

```sh
curl -sS -X PUT https://api.ht-ml.app/v1/sites/1e632471 \
  -H 'content-type: application/json' -H 'authorization: Bearer YZt4WHGKIEb7FeMrGlKo2dWCCsV9w9DrBM7ORf-vHlc' \
  -d '{"html_content":"<html><body><h1>updated via PUT v2</h1></body></html>"}' -w '\nHTTP_STATUS:%{http_code}\n'
curl -sS https://1e632471.ht-ml.app/
```

```text
{"site_id":"1e632471","update_key":"YZt4WHGKIEb7FeMrGlKo2dWCCsV9w9DrBM7ORf-vHlc","status":"active","url":"https://1e632471.ht-ml.app/","message":null}
HTTP_STATUS:200
<html><body><h1>updated via PUT v2</h1></body></html>
```

Same `site_id`, same `update_key`, same `url` across the update; the served content changed
in place. A missing or wrong `Authorization` header is rejected with 401 before this call
was retried correctly, ruling out an unauthenticated update path.

## A password set at creation persists across an update that does not resend it

```sh
curl -sS -X POST https://api.ht-ml.app/v1/sites -H 'content-type: application/json' \
  -d '{"html_content":"<html><body>secret test page</body></html>","password":"testpw123"}'
curl -so /dev/null -w 'HTTP_STATUS:%{http_code}\n' https://f17d7061.ht-ml.app/
curl -sS -X PUT https://api.ht-ml.app/v1/sites/f17d7061 \
  -H 'content-type: application/json' -H 'authorization: Bearer zASufzxw4K8Ar4gKHO7s454JYzI71p822SEXtgcIPc4' \
  -d '{"html_content":"<html><body>secret test page v2</body></html>"}' -w '\nHTTP_STATUS:%{http_code}\n'
curl -so /dev/null -w 'HTTP_STATUS:%{http_code}\n' https://f17d7061.ht-ml.app/
```

```text
{"site_id":"f17d7061","update_key":"zASufzxw4K8Ar4gKHO7s454JYzI71p822SEXtgcIPc4","status":"active","url":"https://f17d7061.ht-ml.app/","message":null}
HTTP_STATUS:401
{"site_id":"f17d7061","update_key":"zASufzxw4K8Ar4gKHO7s454JYzI71p822SEXtgcIPc4","status":"active","url":"https://f17d7061.ht-ml.app/","message":null}
HTTP_STATUS:200
HTTP_STATUS:401
```

The page required the password both before and after the update, with no password resent
on the update call, which is why `fm-decision-ledger-page.sh` generates the password only
once, at first publish, and never needs to resend it.

## Known gap: no verified delete path

`DELETE /v1/sites/<site_id>` with the update key returned `405 Method Not Allowed`, and an
`OPTIONS` preflight on the same path reported `allow: GET`. `fm-decision-ledger-page.sh`
does not attempt a delete for this reason; retiring a project's ledger page today means
removing the local sidecar record and leaving the ht-ml.app page live and orphaned. Re-check
this before adding a delete path.
