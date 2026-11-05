#!/usr/bin/env python3
"""App Store Connect helper for the release workflow.

  asc.py team               -> prints the Team ID (seedId) of the registered bundle id
  asc.py capability NAME    -> makes sure the App ID has a capability (e.g. PUSH_NOTIFICATIONS)
  asc.py submit BUILD_NUM   -> waits for the uploaded build to finish processing,
                               attaches it to the editable App Store version and
                               submits that version for App Review.

Needs env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, APP_VERSION
"""
import json, os, sys, time, urllib.request, urllib.error
import jwt  # pip install pyjwt[crypto]

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.shneitzdadim.app")
APP_VERSION = os.environ.get("APP_VERSION", "1.0")
_tok = {"v": None, "t": 0}


def token():
    if not _tok["v"] or time.time() - _tok["t"] > 900:
        key = open(os.environ["ASC_KEY_PATH"]).read()
        now = int(time.time())
        _tok["v"] = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200,
                                "aud": "appstoreconnect-v1"}, key, algorithm="ES256",
                               headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
        _tok["t"] = now
    return _tok["v"]


def call(method, path, body=None, ok=(200, 201, 204)):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        data = json.loads(raw) if raw else {}
        if e.code in ok:
            return e.code, data
        return e.code, data


def report(st, data, what):
    # every reason Apple gives becomes its own annotation, readable on the run page without signing in
    print(f"\n::error::{what} failed (HTTP {st})")
    for err in data.get("errors", []):
        line = f"{err.get('code', '')}: {err.get('title', '')} | {err.get('detail', '')}".replace("\n", " ")
        print(f"::error title={what}::{line[:900]}")
        for sub in (err.get("meta") or {}).get("associatedErrors", {}).values():
            for x in sub:
                l2 = f"{x.get('code', '')}: {x.get('title', '')} | {x.get('detail', '')}".replace("\n", " ")
                print(f"::error title=missing::{l2[:900]}")


def must(method, path, body=None, what=""):
    st, data = call(method, path, body)
    if st >= 300:
        report(st, data, what or path)
        sys.exit(1)
    return data


def app_id():
    d = must("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}", what="find app")
    apps = [a for a in d["data"] if a["attributes"]["bundleId"] == BUNDLE_ID]
    if not apps:
        print(f"::error::No app with bundle id {BUNDLE_ID} in App Store Connect. Create it first (My Apps -> + -> New App).")
        sys.exit(1)
    return apps[0]["id"]


def team():
    d = must("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE_ID}", what="find bundle id")
    for b in d["data"]:
        if b["attributes"]["identifier"] == BUNDLE_ID:
            print(b["attributes"]["seedId"])
            return
    print(f"::error::Bundle id {BUNDLE_ID} is not registered (developer.apple.com -> Identifiers).", file=sys.stderr)
    sys.exit(1)


def capability(kind):
    d = must("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE_ID}&include=bundleIdCapabilities&limit=5", what="find bundle id")
    b = next((x for x in d["data"] if x["attributes"]["identifier"] == BUNDLE_ID), None)
    if not b:
        print(f"::error::Bundle id {BUNDLE_ID} is not registered."); sys.exit(1)
    have = [x["attributes"]["capabilityType"] for x in d.get("included", []) if x["type"] == "bundleIdCapabilities"]
    if kind in have:
        print(f"{kind}: already on"); return
    st, data = call("POST", "/v1/bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities",
                    "attributes": {"capabilityType": kind},
                    "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": b["id"]}}}}})
    if st >= 300:
        report(st, data, f"enable {kind}")
        print(f"::warning::Could not turn on {kind} for the App ID; Xcode will try during signing.")
        return
    print(f"{kind}: turned on")


def submit(build_num):
    aid = app_id()
    if build_num == "latest":
        d = must("GET", f"/v1/builds?filter[app]={aid}&filter[preReleaseVersion.version]={APP_VERSION}&sort=-uploadedDate&limit=1", what="latest build")
        if not d["data"]:
            print("::error::No uploaded build for this version yet."); sys.exit(1)
        build_num = d["data"][0]["attributes"]["version"]
    print(f"app {aid}, waiting for build {APP_VERSION} ({build_num}) to finish processing…", flush=True)
    build = None
    for i in range(90):  # up to ~60 minutes
        d = must("GET", f"/v1/builds?filter[app]={aid}&filter[version]={build_num}"
                         f"&filter[preReleaseVersion.version]={APP_VERSION}&limit=5", what="list builds")
        if d["data"]:
            build = d["data"][0]
            state = build["attributes"]["processingState"]
            print(f"  build state: {state}", flush=True)
            if state == "VALID":
                break
            if state in ("FAILED", "INVALID"):
                print("::error::Apple rejected the build while processing. Check the email Apple sent.")
                sys.exit(1)
        else:
            print("  not visible yet", flush=True)
        time.sleep(40)
    else:
        print("::error::Build did not finish processing within an hour. Re-run with 'submit only'.")
        sys.exit(1)
    bid = build["id"]

    if build["attributes"].get("usesNonExemptEncryption") is None:
        must("PATCH", f"/v1/builds/{bid}", {"data": {"type": "builds", "id": bid,
             "attributes": {"usesNonExemptEncryption": False}}}, what="export compliance")

    d = must("GET", f"/v1/apps/{aid}/appStoreVersions?filter[platform]=IOS&limit=20", what="list versions")
    editable = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY")
    vers = [v for v in d["data"] if v["attributes"]["appStoreState"] in editable]
    if not vers:
        states = ", ".join(f'{v["attributes"]["versionString"]}={v["attributes"]["appStoreState"]}' for v in d["data"])
        print(f"::error::No editable App Store version. Current: {states or 'none'}")
        sys.exit(1)
    v = next((x for x in vers if x["attributes"]["versionString"] == APP_VERSION), vers[0])
    vid = v["id"]
    print(f"version {v['attributes']['versionString']} ({v['attributes']['appStoreState']})")

    must("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build",
         {"data": {"type": "builds", "id": bid}}, what="attach build to version")
    print(f"::notice title=Build attached::{APP_VERSION} ({build_num}) is now the build of version {v['attributes']['versionString']}")

    # every submission of the app, so the run page shows where things stand
    d = must("GET", f"/v1/reviewSubmissions?filter[app]={aid}&filter[platform]=IOS&limit=20", what="list submissions")
    subs = d["data"]
    for x in subs:
        print(f"::notice title=submission {x['id'][:8]}::{x['attributes'].get('state')} submitted={x['attributes'].get('submittedDate')}")
    # one that already holds this version and can still be sent (e.g. after Apple asked for more information)
    for x in subs:
        st_ = x["attributes"].get("state")
        it = must("GET", f"/v1/reviewSubmissions/{x['id']}/items?include=appStoreVersion", what="submission items")
        has = any(((i.get("relationships") or {}).get("appStoreVersion") or {}).get("data", {}) and
                  i["relationships"]["appStoreVersion"]["data"]["id"] == vid for i in it.get("data", []))
        if not has:
            continue
        if st_ in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
            print(f"::notice title=Already with Apple::Version {APP_VERSION} is {st_} (submission {x['id'][:8]}), now with build {build_num}.")
            print(f"\nAlready submitted ({st_}). Version {APP_VERSION} build {build_num}.")
            return
        if st_ in ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES"):
            # a draft submission left empty by an earlier attempt would only confuse the page in App Store Connect
            for y in subs:
                if y["id"] != x["id"] and y["attributes"].get("state") == "READY_FOR_REVIEW":
                    yi = must("GET", f"/v1/reviewSubmissions/{y['id']}/items", what="draft items")
                    if not yi.get("data"):
                        call("PATCH", f"/v1/reviewSubmissions/{y['id']}", {"data": {"type": "reviewSubmissions", "id": y["id"], "attributes": {"canceled": True}}})
                        print(f"::notice title=Draft removed::empty submission {y['id'][:8]}")
            # right after a new build is attached Apple can answer "not ready yet" for a while: keep trying for 20 minutes
            for attempt in range(21):
                st, data = call("PATCH", f"/v1/reviewSubmissions/{x['id']}", {"data": {"type": "reviewSubmissions", "id": x["id"], "attributes": {"submitted": True}}})
                if st < 300:
                    break
                text = json.dumps(data)
                if "not ready to be submitted" in text and attempt < 20:
                    print(f"  not ready yet, trying again in a minute ({attempt + 1})", flush=True)
                    time.sleep(60)
                    continue
                report(st, data, f"resubmit {st_.lower()} submission")
                sys.exit(1)
            print(f"::notice title=Submitted::Version {APP_VERSION} build {build_num} sent to App Review (submission {x['id'][:8]} was {st_}).")
            print(f"\nSubmitted for App Review. Version {APP_VERSION} build {build_num}.")
            return
    # otherwise: an empty open submission we can use, or a new one
    open_ = [x for x in subs if x["attributes"].get("state") == "READY_FOR_REVIEW"]
    if open_:
        sid = open_[0]["id"]
    else:
        sid = must("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
                   "attributes": {"platform": "IOS"},
                   "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}},
                   what="create review submission")["data"]["id"]

    items = must("GET", f"/v1/reviewSubmissions/{sid}/items", what="list submission items")
    if not items.get("data"):
        st, data = call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems",
                        "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sid}},
                                          "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
        if st >= 300:
            report(st, data, "add version to submission")
            sys.exit(1)

    must("PATCH", f"/v1/reviewSubmissions/{sid}", {"data": {"type": "reviewSubmissions", "id": sid,
         "attributes": {"submitted": True}}}, what="submit for review")
    print(f"::notice title=Submitted::Version {APP_VERSION} build {build_num} sent to App Review.")
    print(f"\nSubmitted for App Review. Version {APP_VERSION} build {build_num}.")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "team":
        team()
    elif cmd == "capability":
        capability(sys.argv[2])
    elif cmd == "submit":
        submit(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
