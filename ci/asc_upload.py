#!/usr/bin/env python3
"""App Store Connect API로 스크린샷과 구독 심사용 스크린샷을 올린다.
키는 Codemagic 통합(환경변수)에서만 읽고, 출력하지 않는다."""
import os, sys, time, json, glob, hashlib, urllib.request, urllib.error
import jwt

APP_ID = os.environ.get("APP_STORE_APPLE_ID", "6835133384")
SUBS = ["6835133410", "6835134547"]
API = "https://api.appstoreconnect.apple.com"


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"], "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"},
                      os.environ["APP_STORE_CONNECT_PRIVATE_KEY"], algorithm="ES256",
                      headers={"kid": os.environ["APP_STORE_CONNECT_KEY_IDENTIFIER"], "typ": "JWT"})


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            t = r.read()
            return json.loads(t) if t else {}
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, method, path, e.read().decode()[:800]); raise


def upload_ops(ops, data):
    for op in ops:
        chunk = data[op["offset"]: op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], method=op["method"], data=chunk, headers={h["name"]: h["value"] for h in op.get("requestHeaders", [])})
        urllib.request.urlopen(req).read()


def upload(kind, attrs_rel, path):
    data = open(path, "rb").read()
    body = {"data": {"type": kind, "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)}, "relationships": attrs_rel}}
    res = call("POST", f"/v1/{kind}", body)["data"]
    upload_ops(res["attributes"]["uploadOperations"], data)
    call("PATCH", f"/v1/{kind}/{res['id']}", {"data": {"type": kind, "id": res["id"], "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    print("uploaded", kind, os.path.basename(path))


def main(folder):
    shots = sorted(glob.glob(os.path.join(folder, "S*.jpg")))
    paywall = [p for p in shots if "paywall" in p]
    store = [p for p in shots if "paywall" not in p] + paywall
    print("files:", [os.path.basename(s) for s in store])

    vers = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?filter[platform]=IOS&limit=5")["data"]
    ver = next(v for v in vers if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"))
    locs = call("GET", f"/v1/appStoreVersions/{ver['id']}/appStoreVersionLocalizations")["data"]
    loc = next(l for l in locs if l["attributes"]["locale"].startswith("ko"))
    sets = call("GET", f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
    sset = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_IPHONE_67"), None)
    if sset is None:
        sset = call("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
                    "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
    for old in call("GET", f"/v1/appScreenshotSets/{sset['id']}/appScreenshots")["data"]:
        call("DELETE", f"/v1/appScreenshots/{old['id']}")
    for p in store:
        upload("appScreenshots", {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sset["id"]}}}, p)

    if paywall:
        for sid in SUBS:
            try:
                cur = call("GET", f"/v1/subscriptions/{sid}/appStoreReviewScreenshot").get("data")
                if cur: call("DELETE", f"/v1/subscriptionAppStoreReviewScreenshots/{cur['id']}")
            except urllib.error.HTTPError:
                pass
            upload("subscriptionAppStoreReviewScreenshots", {"subscription": {"data": {"type": "subscriptions", "id": sid}}}, paywall[0])


if __name__ == "__main__":
    main(sys.argv[1])
