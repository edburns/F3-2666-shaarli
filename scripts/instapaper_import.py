#!/usr/bin/env python3
"""Import Diigo bookmarks into Instapaper via the Full API with tags.

Uses only the Python standard library. No pip installs needed.
Authenticates via xAuth (OAuth 1.0a) and uses bookmarks/add with tags.

Examples:
    # Start from the beginning:
    python3 instapaper_import.py bookmarks.html

    # Verbose output (curl-style HTTP details):
    python3 instapaper_import.py bookmarks.html --verbose

    # Resume a previous run:
    python3 instapaper_import.py bookmarks.html --resume MTAw

    # Load your private environment before running (password is prompted):
    source .env.local

    # Optional command-line overrides:
    python3 instapaper_import.py bookmarks.html \\
        --consumer-key KEY --consumer-secret SECRET
"""

import argparse
import base64
import getpass
import hashlib
import hmac
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

# --- defaults ---------------------------------------------------------------
DEFAULT_CHUNK_SIZE = 100
DELAY_BETWEEN_ADDS = 1.0

XAUTH_URL = "https://www.instapaper.com/api/1/oauth/access_token"
BOOKMARKS_ADD_URL = "https://www.instapaper.com/api/1/bookmarks/add"

VERBOSE = False


# --- helpers ----------------------------------------------------------------

def vprint(*a, **kw):
    if VERBOSE:
        print(*a, **kw)


def make_resume_hash(offset):
    return base64.urlsafe_b64encode(str(offset).encode()).decode().rstrip("=")


def parse_resume_hash(token):
    padded = token + "=" * (-len(token) % 4)
    try:
        return int(base64.urlsafe_b64decode(padded).decode())
    except (ValueError, UnicodeDecodeError):
        print(f"ERROR: invalid resume hash: {token}")
        sys.exit(1)


def parse_bookmarks(path):
    """Parse Diigo HTML into (url, title, tags) tuples."""
    pattern = re.compile(
        r'<DT><A\s+HREF="([^"]*)"[^>]*TAGS="([^"]*)"[^>]*>([^<]*)</A>',
        re.IGNORECASE,
    )
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    results = []
    for m in pattern.finditer(content):
        url, tags_raw, title = m.group(1), m.group(2), m.group(3)
        tags = tags_raw if tags_raw != "no_tag" else ""
        results.append((url, title, tags))
    return results


# --- OAuth 1.0a signing (stdlib only) --------------------------------------

def _percent_encode(s):
    return urllib.parse.quote(str(s), safe="")


def _make_nonce():
    return uuid.uuid4().hex


def _make_signature(method, url, params, consumer_secret, token_secret=""):
    """HMAC-SHA1 signature per OAuth 1.0a."""
    sorted_params = "&".join(
        f"{_percent_encode(k)}={_percent_encode(v)}"
        for k, v in sorted(params.items())
    )
    base_string = "&".join([
        method.upper(),
        _percent_encode(url),
        _percent_encode(sorted_params),
    ])
    signing_key = f"{_percent_encode(consumer_secret)}&{_percent_encode(token_secret)}"
    sig = hmac.new(
        signing_key.encode(), base_string.encode(), hashlib.sha1
    )
    return base64.b64encode(sig.digest()).decode()


def _oauth_header(oauth_params):
    """Build the Authorization header value."""
    pairs = ", ".join(
        f'{_percent_encode(k)}="{_percent_encode(v)}"'
        for k, v in sorted(oauth_params.items())
    )
    return f"OAuth {pairs}"


def oauth_request(method, url, body_params, consumer_key, consumer_secret,
                  token="", token_secret=""):
    """Make an OAuth 1.0a signed request. Returns (status, headers, body)."""
    oauth_params = {
        "oauth_consumer_key": consumer_key,
        "oauth_token": token,
        "oauth_signature_method": "HMAC-SHA1",
        "oauth_timestamp": str(int(time.time())),
        "oauth_nonce": _make_nonce(),
        "oauth_version": "1.0",
    }
    # combine for signature
    all_params = {**oauth_params, **body_params}
    sig = _make_signature(method, url, all_params, consumer_secret, token_secret)
    oauth_params["oauth_signature"] = sig

    auth_header = _oauth_header(oauth_params)
    encoded_body = urllib.parse.urlencode(body_params).encode()

    req = urllib.request.Request(url, data=encoded_body, method=method)
    req.add_header("Authorization", auth_header)
    req.add_header("Content-Type", "application/x-www-form-urlencoded")

    vprint(f"\n> {method} {url}")
    vprint("> Authorization: REDACTED")
    vprint(f"> Content-Type: application/x-www-form-urlencoded")
    vprint("> Body: REDACTED")

    try:
        resp = urllib.request.urlopen(req)
        body = resp.read().decode(errors="replace")
        vprint(f"< HTTP {resp.status} {resp.reason}")
        vprint("< Headers and body: REDACTED")
        return (resp.status, dict(resp.getheaders()), body)
    except urllib.error.HTTPError as e:
        err_body = ""
        try:
            err_body = e.read().decode(errors="replace")
        except Exception:
            pass
        vprint(f"< HTTP {e.code} {e.reason}")
        vprint("< Headers and body: REDACTED")
        return (e.code, dict(e.headers.items()), err_body)
    except urllib.error.URLError as e:
        vprint(f"< URLError: {e.reason}")
        return (0, {}, str(e.reason))


# --- xAuth login ------------------------------------------------------------

def xauth_login(consumer_key, consumer_secret, username, password):
    """Exchange username/password for OAuth access token via xAuth."""
    body = {
        "x_auth_username": username,
        "x_auth_password": password,
        "x_auth_mode": "client_auth",
    }
    status, headers, body_text = oauth_request(
        "POST", XAUTH_URL, body, consumer_key, consumer_secret
    )
    if status != 200:
        print(f"ERROR: xAuth failed (HTTP {status}); response body withheld.")
        sys.exit(1)
    tokens = dict(urllib.parse.parse_qsl(body_text))
    oauth_token = tokens.get("oauth_token", "")
    oauth_secret = tokens.get("oauth_token_secret", "")
    if not oauth_token or not oauth_secret:
        print("ERROR: xAuth response missing tokens; response body withheld.")
        sys.exit(1)
    return oauth_token, oauth_secret


# --- add bookmark -----------------------------------------------------------

def add_bookmark(url, title, tags, consumer_key, consumer_secret,
                 oauth_token, oauth_secret):
    """Add a bookmark via Full API with tags. Returns (success, status, detail)."""
    body = {"url": url}
    if title:
        body["title"] = title
    if tags:
        body["tags"] = tags

    status, headers, resp_body = oauth_request(
        "POST", BOOKMARKS_ADD_URL, body,
        consumer_key, consumer_secret, oauth_token, oauth_secret
    )
    if 200 <= status < 300:
        # parse returned tags from JSON response
        returned_tags = ""
        try:
            data = json.loads(resp_body)
            for item in data:
                if item.get("type") == "bookmark":
                    returned_tags = ",".join(
                        t.get("name", "") for t in
                        [x for x in data if x.get("type") == "tag"]
                    )
                    break
        except (json.JSONDecodeError, TypeError, KeyError):
            pass
        return (True, status, url, returned_tags)
    else:
        return (False, status, f"{url} -- {resp_body[:200]}", "")


# --- prompt -----------------------------------------------------------------

def prompt_action(offset, total):
    while True:
        print(f"\n  Progress: {offset}/{total}")
        print("  1) Process next chunk")
        print("  2) Print resume hash and exit")
        choice = input("  Choice [1/2]: ").strip()
        if choice == "1":
            return
        elif choice == "2":
            token = make_resume_hash(offset)
            print(f"\n  Resume hash: {token}")
            print(f"  To continue later, run:")
            print(f"    python3 {sys.argv[0]} <bookmarks.html> --resume {token}")
            sys.exit(0)
        else:
            print("  Please enter 1 or 2.")


# --- main -------------------------------------------------------------------

def main():
    global VERBOSE

    parser = argparse.ArgumentParser(
        description="Import Diigo bookmarks into Instapaper (Full API, with tags).",
        epilog="Requires only the Python standard library. No pip installs needed.",
    )
    parser.add_argument("html_file",
                        help="Path to the Diigo Chrome export HTML file")
    parser.add_argument("--resume", metavar="HASH",
                        help="Resume hash from a previous run")
    parser.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE,
                        help=f"Bookmarks per chunk (default: {DEFAULT_CHUNK_SIZE})")
    parser.add_argument("--username", default=os.environ.get("INSTAPAPER_USERNAME"),
                        help="Instapaper email (default: INSTAPAPER_USERNAME)")
    parser.add_argument("--consumer-key",
                        default=os.environ.get("INSTAPAPER_CONSUMER_KEY"),
                        help="OAuth consumer key (default: INSTAPAPER_CONSUMER_KEY)")
    parser.add_argument("--consumer-secret",
                        default=os.environ.get("INSTAPAPER_CONSUMER_SECRET"),
                        help="OAuth consumer secret (default: INSTAPAPER_CONSUMER_SECRET)")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Show HTTP status details (credentials and bodies withheld)")
    args = parser.parse_args()
    VERBOSE = args.verbose

    # --- credentials --------------------------------------------------------
    for name, value in (
        ("INSTAPAPER_USERNAME", args.username),
        ("INSTAPAPER_CONSUMER_KEY", args.consumer_key),
        ("INSTAPAPER_CONSUMER_SECRET", args.consumer_secret),
    ):
        if not value or not value.strip() or "REDACTED" in value.upper():
            parser.error(
                f"{name} is missing or redacted; author and source .env.local "
                "or provide the corresponding command-line option"
            )
    consumer_key = args.consumer_key
    consumer_secret = args.consumer_secret
    password = getpass.getpass(f"Instapaper password for {args.username}: ")
    if not password or "REDACTED" in password.upper():
        parser.error("Instapaper password is missing or redacted")

    # --- parse bookmarks ----------------------------------------------------
    bookmarks = parse_bookmarks(args.html_file)
    total = len(bookmarks)
    print(f"Parsed {total} bookmarks from {args.html_file}")

    start = 0
    if args.resume:
        start = parse_resume_hash(args.resume)
        if start >= total:
            print(f"Resume offset {start} >= {total} bookmarks. Nothing to do.")
            sys.exit(0)
        print(f"Resuming from bookmark {start + 1}")

    # --- xAuth login --------------------------------------------------------
    print("\nAuthenticating via xAuth...")
    oauth_token, oauth_secret = xauth_login(
        consumer_key, consumer_secret, args.username, password
    )
    print("  Authenticated OK.")

    # --- test with first bookmark -------------------------------------------
    print("\nTesting with first bookmark...")
    url, title, tags = bookmarks[start]
    ok, status, detail, returned_tags = add_bookmark(
        url, title, tags,
        consumer_key, consumer_secret, oauth_token, oauth_secret
    )
    if not ok:
        print(f"ERROR (HTTP {status}): {detail}")
        sys.exit(1)
    tag_info = f" [sent: {tags}]" if tags else " [no tags]"
    ret_info = f" [returned: {returned_tags}]" if returned_tags else " [returned: none]"
    print(f"  OK (HTTP {status}): {url[:72]}{tag_info}{ret_info}")

    # --- process chunks -----------------------------------------------------
    offset = start + 1
    while offset < total:
        chunk_end = min(offset + args.chunk_size, total)
        chunk = bookmarks[offset:chunk_end]
        chunk_num = (offset - start) // args.chunk_size + 1

        print(f"\n--- Chunk {chunk_num}: bookmarks {offset + 1}-{chunk_end} of {total} ---")

        ok_count = 0
        fail_count = 0
        for i, (url, title, tags) in enumerate(chunk, start=1):
            ok, status, detail, returned_tags = add_bookmark(
                url, title, tags,
                consumer_key, consumer_secret, oauth_token, oauth_secret
            )
            if ok:
                ok_count += 1
                tag_info = f" [sent: {tags}]" if tags else ""
                ret_info = f" [got: {returned_tags}]" if returned_tags else ""
                if VERBOSE:
                    print(f"  [{offset + i}/{total}] OK: {url}{tag_info}{ret_info}")
                else:
                    print(f"  [{offset + i}/{total}] OK: {url[:60]}{tag_info}{ret_info}")
            else:
                fail_count += 1
                if VERBOSE:
                    print(f"  [{offset + i}/{total}] FAIL ({status}): {detail}")
                else:
                    print(f"  [{offset + i}/{total}] FAIL ({status}): {url[:60]}")
            time.sleep(DELAY_BETWEEN_ADDS)

        offset = chunk_end
        print(f"\nChunk done: {ok_count} ok, {fail_count} failed.")

        if offset < total:
            prompt_action(offset, total)
        else:
            print(f"\nAll done. {offset} bookmarks processed.")


if __name__ == "__main__":
    main()
