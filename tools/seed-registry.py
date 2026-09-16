#!/usr/bin/env python3
"""tools/seed-registry.py -- put an image into a registry, over the API.

    seed-registry.py <docker-save tar> <base url> <repo> <tag> [ca.pem]

WHY NOT `docker push`. The daemon that would do the pushing lives in a virtual
machine of its own, where "localhost" is that machine and not this one, so it
cannot reach a registry running here. This speaks the distribution API
directly: blobs by monolithic upload, then the manifest under the tag.

WHAT IT PUSHES. `docker save` writes an OCI layout whose top-level entry is an
image INDEX -- one manifest per platform. This picks the one for the platform
asked for and pushes THAT, so what lands under the tag is a plain manifest.
The daemon being tested can read an index too; pushing one here would be
testing the seeder's choices rather than the daemon's.
"""
import json, ssl, sys, tarfile, urllib.request, urllib.error

CTX = None      # a CA to trust instead of the system store, for a test registry

def req(method, url, data=None, ctype=None, headers=None):
    h = dict(headers or {})
    if ctype:
        h["Content-Type"] = ctype
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        return urllib.request.urlopen(r, context=CTX)
    except urllib.error.HTTPError as e:
        return e

def main():
    global CTX
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    tar_path, base, repo, tag = sys.argv[1:5]
    if len(sys.argv) == 6:
        CTX = ssl.create_default_context(cafile=sys.argv[5])
    base = base.rstrip("/")
    plat = ("linux", "arm64")

    with tarfile.open(tar_path) as t:
        def blob(digest):
            return t.extractfile("blobs/" + digest.replace(":", "/")).read()
        index = json.loads(t.extractfile("index.json").read())
        top = index["manifests"][0]
        doc = json.loads(blob(top["digest"]))
        if "manifests" in doc:                      # an index: pick a platform
            want = [m for m in doc["manifests"]
                    if m.get("platform", {}).get("os") == plat[0]
                    and m.get("platform", {}).get("architecture") == plat[1]]
            if not want:
                sys.exit("seed-registry: no %s/%s manifest in %s" % (plat + (tar_path,)))
            mdesc = want[0]
            mbytes = blob(mdesc["digest"])
            mtype = mdesc["mediaType"]
        else:
            mbytes, mtype = blob(top["digest"]), top["mediaType"]
        manifest = json.loads(mbytes)

        # Every blob the manifest names, then the manifest itself. In that
        # order, because a registry is entitled to refuse a manifest whose
        # blobs are not there yet -- and one that does not is not being tested.
        for d in [manifest["config"]] + manifest["layers"]:
            body = blob(d["digest"])
            r = req("POST", "%s/v2/%s/blobs/uploads/" % (base, repo))
            if r.status not in (202, 200):
                sys.exit("seed-registry: upload start -> %d" % r.status)
            loc = r.headers["Location"]
            if loc.startswith("/"):
                loc = base + loc
            sep = "&" if "?" in loc else "?"
            r = req("PUT", "%s%sdigest=%s" % (loc, sep, d["digest"]), body,
                    "application/octet-stream")
            if r.status != 201:
                sys.exit("seed-registry: blob %s -> %d" % (d["digest"][:19], r.status))
            print("  blob %s (%d bytes)" % (d["digest"][:19], len(body)))

        r = req("PUT", "%s/v2/%s/manifests/%s" % (base, repo, tag), mbytes, mtype)
        if r.status != 201:
            sys.exit("seed-registry: manifest -> %d" % r.status)
        print("  manifest %s:%s -> %s" % (repo, tag, r.headers.get("Docker-Content-Digest", "")))

main()
