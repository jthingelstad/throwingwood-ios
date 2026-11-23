#!/usr/bin/env python3
"""Upload App Store screenshots and app previews for one version localization.

  tools/asc-upload-media.py shots   <displayType> <file>...     e.g. APP_IPHONE_67
  tools/asc-upload-media.py preview <previewType> <file> [poster-timecode]   e.g. IPHONE_67

The 1.0.0 pictures went up with APP_IPHONE_67 (1320 x 2868) and
APP_IPAD_PRO_3GEN_129 (2064 x 2752). Every upload is the owner's call.

Run from the throwingwood-ios checkout (uses scripts/asc.swift for API calls).
Files are added to the set in the order given. An existing set of the same
type is reused; nothing already in it is removed.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import urllib.request

LOC = "183dc5ed-f18e-43fa-8fa0-5c016f09aba8"


def asc(method, path, body=None):
    args = ["scripts/asc.swift", method, path]
    tmp = None
    if body is not None:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(body, tmp)
        tmp.close()
        args.append(tmp.name)
    out = subprocess.run(args, capture_output=True, text=True)
    if tmp:
        os.unlink(tmp.name)
    head, _, rest = out.stdout.partition("\n")
    data = json.loads(rest) if rest.strip() else {}
    if not head.startswith("HTTP 2"):
        sys.exit(f"{method} {path}: {head}\n{json.dumps(data.get('errors'), indent=1)}\n{out.stderr}")
    return data


def put_parts(path, ops):
    with open(path, "rb") as f:
        blob = f.read()
    for op in ops:
        chunk = blob[op["offset"]: op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for h in op.get("requestHeaders", []):
            req.add_header(h["name"], h["value"])
        with urllib.request.urlopen(req, timeout=300) as r:
            if r.status >= 300:
                sys.exit(f"upload part failed: {r.status}")
    return hashlib.md5(blob).hexdigest()


def find_or_make_set(kind, type_attr, type_value):
    sets = asc("GET", f"/v1/appStoreVersionLocalizations/{LOC}/{kind}?limit=50")["data"]
    for s in sets:
        if s["attributes"][type_attr] == type_value:
            return s["id"]
    made = asc("POST", f"/v1/{kind}", {"data": {
        "type": kind, "attributes": {type_attr: type_value},
        "relationships": {"appStoreVersionLocalization": {
            "data": {"type": "appStoreVersionLocalizations", "id": LOC}}}}})
    return made["data"]["id"]


def shots(display, files):
    set_id = find_or_make_set("appScreenshotSets", "screenshotDisplayType", display)
    ids = []
    for f in files:
        made = asc("POST", "/v1/appScreenshots", {"data": {
            "type": "appScreenshots",
            "attributes": {"fileName": os.path.basename(f), "fileSize": os.path.getsize(f)},
            "relationships": {"appScreenshotSet": {
                "data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
        md5 = put_parts(f, made["attributes"]["uploadOperations"])
        asc("PATCH", f"/v1/appScreenshots/{made['id']}", {"data": {
            "type": "appScreenshots", "id": made["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": md5}}})
        ids.append(made["id"])
        print("uploaded", os.path.basename(f), made["id"])
    asc("PATCH", f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots",
        {"data": [{"type": "appScreenshots", "id": i} for i in ids]})
    print("set", set_id, "ordered", len(ids))


def preview(ptype, f, timecode=None):
    set_id = find_or_make_set("appPreviewSets", "previewType", ptype)
    attrs = {"fileName": os.path.basename(f), "fileSize": os.path.getsize(f),
             "mimeType": "video/mp4" if f.endswith(".mp4") else "video/quicktime"}
    if timecode:
        attrs["previewFrameTimeCode"] = timecode
    made = asc("POST", "/v1/appPreviews", {"data": {
        "type": "appPreviews", "attributes": attrs,
        "relationships": {"appPreviewSet": {
            "data": {"type": "appPreviewSets", "id": set_id}}}}})["data"]
    md5 = put_parts(f, made["attributes"]["uploadOperations"])
    asc("PATCH", f"/v1/appPreviews/{made['id']}", {"data": {
        "type": "appPreviews", "id": made["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": md5}}})
    print("uploaded", os.path.basename(f), made["id"], "set", set_id)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    if sys.argv[1] == "shots":
        shots(sys.argv[2], sys.argv[3:])
    elif sys.argv[1] == "preview":
        preview(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
    else:
        sys.exit(__doc__)
